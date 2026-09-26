// CTCForcedAligner.swift
//
// On-device forced alignment of lyric lines to a song. Pipeline: isolate vocals (HTDemucs
// CoreML, cached per audio file) → 16 kHz → per-frame CTC log-probabilities from Meta's MMS
// forced aligner (wav2vec2, CoreML, see [[MMSEmissions]]) over the whole stem and the raw mix →
// [[CTCAlignmentCore]]: mix fill, energy-VAD pin, one CTC Viterbi pass over the whole romanized
// lyric, per-line/per-span times.
//
// The aligner reads romanized text, so the caller supplies each line's romanization as spans
// that carry the UTF-16 range of the line text they cover ([[RomanizedSpan]]); those spans
// become the per-line karaoke checkpoints.

import Accelerate
import Foundation
import AVFoundation
import CoreML

public struct CTCForcedAligner {
    public init() {}

    // Aligns lyric lines to the audio, returning one AlignedLine per input line plus per-span
    // checkpoints. Progress is reported both as a fraction and as human-readable stage text.
    public func align(
        input: AlignmentInput,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        // Awaited before each vocal-isolation chunk; see HTDemucsCoreMLSeparator.isolateVocalsMono.
        waitUntilReady: (@Sendable () async -> Void)? = nil,
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

        // The raw mix is always needed too: it stands in for the stem wherever isolation erased
        // the voice (see EmissionDropoutFill).
        onStage?("Decoding audio…")
        let stereo = try await Self.decodeStereoFloat(from: input.audioURL)
        guard stereo.count == 2, stereo[0].isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
        }
        Self.breadcrumb("decoded stereo \(stereo[0].count) frames (~\(stereo[0].count / 44_100)s)")
        let mixMono = zip(stereo[0], stereo[1]).map { ($0 + $1) * 0.5 }

        // Vocal isolation is the most expensive stage and a pure function of the source audio,
        // so a re-align of unchanged audio loads the stem off disk.
        let vocalMono: [Float]
        if let cached = VocalStemCache.load(for: input.audioURL) {
            Self.breadcrumb("vocal stem CACHE HIT \(cached.count) frames (~\(cached.count / 44_100)s)")
            onStage?("Loading cached vocals…")
            vocalMono = cached
        } else {
            onProgress?(0.05)
            onStage?("Isolating…")
            let mono = try await HTDemucsCoreMLSeparator.isolateVocalsMono(
                stereo: stereo,
                cancellationCheck: cancellationCheck,
                waitUntilReady: waitUntilReady,
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
            // Defense in depth alongside HTDemucsCoreMLSeparator now throwing on cancellation
            // instead of returning a silent partial result: a genuinely-completed isolation of
            // real audio always has some peak above float noise floor, so a near-zero peak means
            // the "isolation" is garbage regardless of which path produced it. Caching it would
            // permanently poison every future Re-align of this song (VocalStemCache.load is a
            // pure cache hit with no re-validation) — reject before that happens instead of
            // silently writing a stem that will look like a completed isolation forever.
            var peak: Float = 0
            vDSP_maxmgv(mono, 1, &peak, vDSP_Length(mono.count))
            guard peak > 1e-4 else {
                throw NSError(domain: "SwiftWhisperAlign.CTC", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced silence."])
            }
            Self.breadcrumb("isolated voice \(mono.count) frames (HTDemucs CoreML)")
            VocalStemCache.store(mono, for: input.audioURL)
            vocalMono = mono
        }
        VocalStemCache.storeInstrumental(mix: stereo, vocals: vocalMono, for: input.audioURL)
        onProgress?(0.4)

        onStage?("Preparing aligner…")
        let model = try await MMSEmissions.loadModel(onStage: onStage)
        Self.breadcrumb("aligner model loaded")
        if cancellationCheck?() == true { throw CancellationError() }

        onStage?("Aligning lyrics…")
        let audio16k = try MMSEmissions.resample(vocalMono, from: 44_100)
        let matrix = try MMSEmissions.logProbs(
            model: model, audio: audio16k, cancellationCheck: cancellationCheck,
            onProgress: { frac in
                onProgress?(0.45 + 0.25 * frac)
                onStage?("Aligning lyrics… \(Int((50 * frac).rounded()))%")
            }
        )
        Self.breadcrumb("emissions \(matrix.frames) frames × \(MMSEmissions.classes)")
        #if DEBUG
        Self.debugDump(matrix.values.withUnsafeBufferPointer { Data(buffer: $0) },
                       name: "\(VocalStemCache.identityKey(for: input.audioURL)).emissions.f32")
        #endif
        let mixMatrix = try MMSEmissions.logProbs(
            model: model, audio: try MMSEmissions.resample(mixMono, from: 44_100), cancellationCheck: cancellationCheck,
            onProgress: { frac in
                onProgress?(0.70 + 0.20 * frac)
                onStage?("Aligning lyrics… \(50 + Int((50 * frac).rounded()))%")
            }
        )
        #if DEBUG
        Self.debugDump(mixMatrix.values.withUnsafeBufferPointer { Data(buffer: $0) },
                       name: "\(VocalStemCache.identityKey(for: input.audioURL)).mix-emissions.f32")
        #endif
        #if DEBUG
        Self.debugDump(Data(input.romanization.map { $0.map(\.romaji).joined(separator: "|") }.joined(separator: "\n").utf8),
                       name: "\(VocalStemCache.identityKey(for: input.audioURL)).romaji.txt")
        #endif
        let (lines, lineTokens) = try CTCAlignmentCore.align(
            stem: matrix, mix: mixMatrix, vocalMono: vocalMono,
            lines: input.lines, romanization: input.romanization,
            log: { Self.breadcrumb($0) }
        )
        onProgress?(0.95)
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
        waitUntilReady: (@Sendable () async -> Void)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Float] {
        if let cached = VocalStemCache.load(for: url), cached.isEmpty == false { return cached }
        let stereo = try await decodeStereoFloat(from: url)
        guard stereo.count == 2, stereo[0].isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
        }
        let mono = try await HTDemucsCoreMLSeparator.isolateVocalsMono(
            stereo: stereo, cancellationCheck: cancellationCheck,
            waitUntilReady: waitUntilReady, onProgress: onProgress)
        guard mono.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Vocal isolation produced no output."])
        }
        VocalStemCache.store(mono, for: url)
        return mono
    }

    // Decodes any audio file to 44.1 kHz stereo 32-bit float PCM via AVAssetReader.
    // Deinterleaves into [left, right].
    static func decodeStereoFloat(from url: URL) async throws -> [[Float]] {
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
