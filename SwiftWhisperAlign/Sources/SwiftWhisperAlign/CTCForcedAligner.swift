// CTCForcedAligner.swift
//
// On-device forced alignment via soniqo's Qwen3ForcedAligner (CTC). Replaces the
// Whisper cross-attention DTW path (ForcedAligner), which collapsed on full songs
// (~101 s median error vs the stable-ts oracle, 0% of lines within ±500 ms). CTC
// computes a monotonic alignment of the known text against per-frame token
// probabilities in a single forward pass, so it cannot "lose its place" the way the
// DTW timing-extraction hack did. Measured on the same fixture: ~3.9 s median on the
// vocal stem — a 26× improvement.
//
// The 0.6B model is downloaded on first use via fromPretrained() and cached in the
// app sandbox; nothing is bundled in the binary.

import Foundation
import AVFoundation
import Qwen3ASR

public struct CTCForcedAligner {
    // Qwen3ForcedAligner expects 24 kHz mono float audio.
    private static let sampleRate = 24_000

    public init() {}

    // Aligns lyric lines to the audio, returning one AlignedLine per input line.
    public func align(
        input: AlignmentInput,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onSegment: (@Sendable ([AlignedLine]) -> Void)? = nil
    ) async throws -> AlignmentResult {
        guard input.lines.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align."])
        }
        if cancellationCheck?() == true { throw CancellationError() }

        let fullSamples = try await Self.decode24kMonoFloat(from: input.audioURL)
        guard fullSamples.isEmpty == false else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames."])
        }
        // [TEMP DIAGNOSTIC] Cap audio to 60s to test whether full-song length is the
        // on-device OOM cause. If a 60s clip survives, the fix is chunking. Remove after.
        let samples = Array(fullSamples.prefix(60 * Self.sampleRate))
        onProgress?(0.1)

        // Downloads the model on first use; cached thereafter.
        let aligner = try await Qwen3ForcedAligner.fromPretrained()
        if cancellationCheck?() == true { throw CancellationError() }

        let text = input.lines.joined(separator: "\n")
        let aligned = aligner.align(audio: samples, text: text, sampleRate: Self.sampleRate)
        onProgress?(0.9)

        // Decouple from the soniqo result type — pull starts/texts/end into plain arrays.
        var unitStarts: [Double] = []
        var unitTexts: [String] = []
        var lastEnd: Double = 0
        for unit in aligned {
            unitStarts.append(Double(unit.startTime))
            unitTexts.append(unit.text)
            lastEnd = max(lastEnd, Double(unit.endTime))
        }

        let lines = Self.mapUnitsToLines(
            starts: unitStarts, texts: unitTexts, lastEnd: lastEnd, lines: input.lines
        )
        onSegment?(lines)
        onProgress?(1.0)
        return AlignmentResult(lines: lines)
    }

    // Aligns and returns SRT text — drop-in for ForcedAligner.alignToSRT.
    public func alignToSRT(
        input: AlignmentInput,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onSegment: (@Sendable ([AlignedLine]) -> Void)? = nil
    ) async throws -> String {
        let result = try await align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onSegment: onSegment
        )
        return SRTWriter.write(result)
    }

    // Maps the aligner's per-unit (start, text) output onto the input lines by
    // accumulating non-whitespace characters: a line's start is the start time of the
    // unit covering that line's first character. Ends run to the next line's start.
    private static func mapUnitsToLines(
        starts: [Double],
        texts: [String],
        lastEnd: Double,
        lines: [String]
    ) -> [AlignedLine] {
        func nonWS(_ s: String) -> Int { s.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 } }

        // Per-character start times, in text order.
        var charStart: [Double] = []
        for (i, t) in texts.enumerated() {
            let n = nonWS(t)
            if n > 0 { charStart.append(contentsOf: repeatElement(starts[i], count: n)) }
        }

        // Each line's first-character index, then its start time.
        var lineStarts: [Double] = []
        var cum = 0
        for line in lines {
            let s = charStart.isEmpty ? 0 : charStart[min(cum, charStart.count - 1)]
            lineStarts.append(s)
            cum += nonWS(line)
        }

        var result: [AlignedLine] = []
        for (i, line) in lines.enumerated() {
            let start = lineStarts[i]
            let end = (i + 1 < lines.count) ? max(start + 0.3, lineStarts[i + 1]) : max(start + 0.3, lastEnd)
            result.append(AlignedLine(text: line, start: start, end: end))
        }
        return result
    }

    // Decodes any audio file to 24 kHz mono 32-bit float PCM via AVAssetReader.
    private static func decode24kMonoFloat(from url: URL) async throws -> [Float] {
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
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
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

        var frames: [Float] = []
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
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            frames.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: count))
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "SwiftWhisperAlign.CTC", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding."])
        }
        return frames
    }
}
