// CTCForcedAligner.swift
//
// On-device forced alignment of lyric lines to a song. Pipeline: isolate vocals (HTDemucs
// CoreML, cached per audio file) → 16 kHz → per-frame CTC log-probabilities from Meta's MMS
// forced aligner (wav2vec2, CoreML, see [[MMSEmissions]]) over the whole stem → pin the
// frames outside the sung regions (energy VAD) to blank → one CTC Viterbi pass over the whole
// romanized lyric → per-line/per-span times.
//
// The aligner reads romanized text, so the caller supplies each line's romanization as spans
// that carry the UTF-16 range of the line text they cover ([[RomanizedSpan]]); those spans
// become the per-line karaoke checkpoints.

import Foundation
import AVFoundation
import CoreML

public struct CTCForcedAligner {
    public init() {}

    // CTC fires a token at the end of its phone, so every start lands late by roughly a
    // consonant. Swept on device against the oracle: 0.20 s gives the best median and coverage
    // (0.30 and 0.40 trade median for nothing).
    static let startLead = 0.20
    // Frames this far outside a sung region are pinned to blank.
    static let regionMargin = 0.5

    // Aligns lyric lines to the audio, returning one AlignedLine per input line plus per-span
    // checkpoints. Progress is reported both as a fraction and as human-readable stage text.
    public func align(
        input: AlignmentInput,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil,
        onSegment: (@Sendable ([AlignedLine]) -> Void)? = nil
    ) async throws -> AlignmentResult {
        guard input.lines.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align."])
        }
        guard input.romanization.count == input.lines.count else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Romanization does not match the lyric lines."])
        }
        if cancellationCheck?() == true { throw CancellationError() }

        Self.breadcrumb("RUN START", reset: true)
        Self.breadcrumb("stem cache \(VocalStemCache.debugKeyInfo(for: input.audioURL))")

        // Vocal isolation is the most expensive stage and a pure function of the source audio,
        // so a re-align of unchanged audio loads the stem off disk.
        let vocalMono: [Float]
        if let cached = VocalStemCache.load(for: input.audioURL) {
            Self.breadcrumb("vocal stem CACHE HIT \(cached.count) frames (~\(cached.count / 44_100)s)")
            onStage?("Loading cached vocals…")
            vocalMono = cached
        } else {
            onStage?("Decoding audio…")
            let stereo = try await Self.decodeStereoFloat(from: input.audioURL)
            guard stereo.count == 2, stereo[0].isEmpty == false else {
                throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
            }
            Self.breadcrumb("decoded stereo \(stereo[0].count) frames (~\(stereo[0].count / 44_100)s)")
            onProgress?(0.05)
            onStage?("Isolating…")
            let mono = try await HTDemucsCoreMLSeparator.isolateVocalsMono(
                stereo: stereo,
                cancellationCheck: cancellationCheck,
                onProgress: { frac in
                    onProgress?(0.10 + 0.30 * frac)
                    onStage?("Isolating… \(Int((frac * 100).rounded()))%")
                },
                onStage: onStage
            )
            guard mono.isEmpty == false else {
                throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                              userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
            }
            Self.breadcrumb("isolated voice \(mono.count) frames (HTDemucs CoreML)")
            VocalStemCache.store(mono, for: input.audioURL)
            vocalMono = mono
        }
        onProgress?(0.4)

        onStage?("Preparing aligner…")
        let model = try await MMSEmissions.loadModel(onStage: onStage)
        Self.breadcrumb("aligner model loaded")
        if cancellationCheck?() == true { throw CancellationError() }

        onStage?("Aligning lyrics…")
        let audio16k = try MMSEmissions.resample(vocalMono, from: 44_100)
        var matrix = try MMSEmissions.logProbs(
            model: model, audio: audio16k, cancellationCheck: cancellationCheck,
            onProgress: { frac in onProgress?(0.45 + 0.45 * frac) }
        )
        Self.breadcrumb("emissions \(matrix.frames) frames × \(MMSEmissions.classes)")
        #if DEBUG
        Self.debugDump(matrix.values.withUnsafeBufferPointer { Data(buffer: $0) },
                       name: "\(VocalStemCache.identityKey(for: input.audioURL)).emissions.f32")
        #endif

        // Outside the sung regions the emissions are weak and near-blank, and the DP would
        // happily start the next line anywhere inside an interlude. Pinning those frames to
        // blank makes the sung regions the only place text can land.
        let regions = EnergyVAD.regions(vocalMono, sampleRate: 44_100)
        Self.breadcrumb("energy-VAD \(regions.count) regions: " + regions.prefix(12).map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: " "))
        if regions.isEmpty == false {
            var sung = [Bool](repeating: false, count: matrix.frames)
            for r in regions {
                let f0 = max(0, Int((r.start - Self.regionMargin) / matrix.frameSec))
                let f1 = min(matrix.frames, Int((r.end + Self.regionMargin) / matrix.frameSec))
                if f1 > f0 { for f in f0..<f1 { sung[f] = true } }
            }
            let C = MMSEmissions.classes
            for f in 0..<matrix.frames where sung[f] == false {
                for c in 0..<C { matrix.values[f * C + c] = -1e4 }
                matrix.values[f * C + MMSEmissions.blank] = 0
            }
        }

        // Flatten every span's romaji into one token sequence, remembering each span's range.
        var tokens: [Int] = []
        var spanTokenRanges: [[Range<Int>]] = []   // per line, per span
        for lineSpans in input.romanization {
            var ranges: [Range<Int>] = []
            for span in lineSpans {
                let start = tokens.count
                for ch in span.romaji {
                    if let idx = MMSEmissions.labels.firstIndex(of: ch), idx != MMSEmissions.blank {
                        tokens.append(idx)
                    }
                }
                ranges.append(start..<tokens.count)
            }
            spanTokenRanges.append(ranges)
        }
        #if DEBUG
        Self.debugDump(Data(input.romanization.map { $0.map(\.romaji).joined(separator: "|") }.joined(separator: "\n").utf8),
                       name: "\(VocalStemCache.identityKey(for: input.audioURL)).romaji.txt")
        #endif
        guard tokens.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The lyrics romanized to nothing alignable."])
        }
        guard let spans = CTCViterbi.align(logProbs: matrix.values, frames: matrix.frames,
                                           classes: MMSEmissions.classes, tokens: tokens) else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "The lyrics don't fit the sung audio (more text than the song can hold)."])
        }
        Self.breadcrumb("viterbi placed \(tokens.count) tokens")
        onProgress?(0.95)

        let (lines, lineTokens) = Self.lineTimings(
            lines: input.lines, romanization: input.romanization, spanTokenRanges: spanTokenRanges,
            tokenSpans: spans, frameSec: matrix.frameSec, durationSec: Double(vocalMono.count) / 44_100
        )
        onSegment?(lines)
        onProgress?(1.0)
        return AlignmentResult(lines: lines, lineTokens: lineTokens)
    }

    // Isolated vocal stem (mono, 44.1 kHz) for `url` — from the shared on-disk cache when
    // present (alignment populates the same cache), otherwise isolated via HTDemucs CoreML and
    // cached. Lets transcription feed the ASR clean vocals instead of the full mix.
    public static func isolatedVocalStem(
        for url: URL,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Float] {
        if let cached = VocalStemCache.load(for: url), cached.isEmpty == false { return cached }
        let stereo = try await decodeStereoFloat(from: url)
        guard stereo.count == 2, stereo[0].isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
        }
        let mono = try await HTDemucsCoreMLSeparator.isolateVocalsMono(
            stereo: stereo, cancellationCheck: cancellationCheck, onProgress: onProgress)
        guard mono.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
        }
        VocalStemCache.store(mono, for: url)
        return mono
    }

    // Turns token spans into per-line timings and per-span checkpoints. A line starts at its
    // first placed token (less `startLead`) and ends at its last; the end is bridged to the
    // next line's start when the gap is short (a held final vowel plus a breath — CTC leaves
    // the token as soon as the phone is recognizable, so its own end lands well before the
    // singer stops), while a longer gap stays open for a ♪ marker.
    private static func lineTimings(
        lines: [String], romanization: [[RomanizedSpan]], spanTokenRanges: [[Range<Int>]],
        tokenSpans: [(start: Int, end: Int)], frameSec: Double, durationSec: Double
    ) -> (lines: [AlignedLine], lineTokens: [[AlignedToken]]) {
        let sustainedVowelGap = 4.0
        let bridgeMargin = 0.05
        let perceptualOffset = 0.20
        func time(_ frame: Int) -> Double { Double(frame) * frameSec }

        // Per line: first/last placed token frames (nil when the line romanized to nothing).
        var lineStart: [Double?] = []
        var lineEnd: [Double?] = []
        for ranges in spanTokenRanges {
            let placed = ranges.flatMap { Array($0) }
            if let first = placed.first, let last = placed.last {
                lineStart.append(max(0, time(tokenSpans[first].start) - startLead))
                lineEnd.append(time(tokenSpans[last].end))
            } else {
                lineStart.append(nil); lineEnd.append(nil)
            }
        }
        // A line with no tokens borrows its neighbours' boundary so it is never dropped.
        for i in lines.indices where lineStart[i] == nil {
            let prevEnd = (0..<i).reversed().compactMap { lineEnd[$0] }.first ?? 0
            let nextStart = ((i + 1)..<lines.count).compactMap { lineStart[$0] }.first ?? durationSec
            lineStart[i] = prevEnd
            lineEnd[i] = min(nextStart, prevEnd + 0.3)
        }

        var result: [AlignedLine] = []
        var lineTokens: [[AlignedToken]] = []
        for i in lines.indices {
            let start = lineStart[i]!
            let nextBound = (i + 1 < lines.count) ? lineStart[i + 1]! : durationSec
            let ctcEnd = lineEnd[i]! + perceptualOffset
            let gapAfter = nextBound - ctcEnd
            let extendedEnd = (gapAfter > 0 && gapAfter <= sustainedVowelGap) ? nextBound - bridgeMargin : ctcEnd
            let end = max(start + 0.3, min(extendedEnd, nextBound, start + 9.0))
            result.append(AlignedLine(text: lines[i], start: start, end: end))

            var tokens: [AlignedToken] = []
            var lastStart = -Double.infinity
            for (span, range) in zip(romanization[i], spanTokenRanges[i]) {
                guard let first = range.first else { continue }
                var t = max(start, time(tokenSpans[first].start) - startLead)
                // Keep checkpoints distinct and forward-only, clamped to the line end.
                if t < lastStart + 0.1 { t = min(lastStart + 0.1, end) }
                lastStart = t
                tokens.append(AlignedToken(start: t, charOffsetUTF16: span.charOffsetUTF16, charLengthUTF16: span.charLengthUTF16))
            }
            lineTokens.append(tokens)
        }
        return (result, lineTokens)
    }

    // Decodes any audio file to 44.1 kHz stereo 32-bit float PCM via AVAssetReader.
    // Deinterleaves into [left, right].
    private static func decodeStereoFloat(from url: URL) async throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track in the selected file."])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader."])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "SwiftWhisperAlign.CTC", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."])
        }
        var left: [Float] = []
        var right: [Float] = []
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength, dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else { continue }
            let count = dataLength / MemoryLayout<Float>.size
            let fp = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            var i = 0
            while i + 1 < count { left.append(fp[i]); right.append(fp[i + 1]); i += 2 }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "SwiftWhisperAlign.CTC", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding."])
        }
        return [left, right]
    }
}
