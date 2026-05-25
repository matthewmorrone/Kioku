// TranscriptionValidator.swift
// Runs unconstrained Whisper speech-to-text over an audio file and exposes the
// resulting timestamped segments. Used to validate forced-alignment quality —
// callers compare the existing subtitle text in each cue's time range against
// what Whisper actually transcribed in that range.

import AVFoundation
import whisper_cpp

public struct TranscriptionValidator {
    /// One Whisper-emitted segment with its time range and recognized text.
    public struct Segment: Equatable {
        public let start: Double
        public let end: Double
        public let text: String
        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Runs Whisper on the full audio and returns its emitted segments. Unlike
    /// the forced-alignment path, no logits filter is installed — Whisper is
    /// free to transcribe whatever it hears, with its own timestamps.
    public static func transcribe(
        audioURL: URL,
        modelURL: URL,
        language: String = "ja",
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [Segment] {
        let frames = try await decodeAudioFrames(from: audioURL)
        guard frames.isEmpty == false else { return [] }

        var cparams = whisper_context_default_params()
        guard let ctx = modelURL.path.withCString({ path in
            whisper_init_from_file_with_params(path, cparams)
        }) else {
            throw NSError(
                domain: "SwiftWhisperAlign.TranscriptionValidator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load Whisper model from \(modelURL.lastPathComponent)."]
            )
        }
        defer { whisper_free(ctx) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // Print/log nothing — the library otherwise spams stderr per segment.
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        // Language hint helps multilingual models pick the right tokenizer path.
        let langCString = strdup(language)
        defer { if let langCString { free(langCString) } }
        params.language = UnsafePointer(langCString)

        // Run on a background queue so the synchronous whisper_full doesn't block
        // the caller's actor; cooperative cancellation is checked between segments
        // via abort_callback.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = frames.withUnsafeBufferPointer { buf -> Int32 in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
                continuation.resume(returning: r)
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: "SwiftWhisperAlign.TranscriptionValidator",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "whisper_full failed (code \(result))"]
            )
        }

        if cancellationCheck?() == true { return [] }

        let count = whisper_full_n_segments(ctx)
        var segments: [Segment] = []
        segments.reserveCapacity(Int(count))
        for i in 0..<count {
            // Timestamps are in 10 ms units (Whisper's standard).
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) * 0.01
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) * 0.01
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }
            segments.append(Segment(start: t0, end: t1, text: text))
        }
        onProgress?(1.0)
        return segments
    }

    // Decodes audio to 16 kHz mono float frames so Whisper's 16 kHz expectation
    // is satisfied.
    private static func decodeAudioFrames(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "SwiftWhisperAlign.TranscriptionValidator",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No audio track in file."]
            )
        }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(
                domain: "SwiftWhisperAlign.TranscriptionValidator",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader."]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "SwiftWhisperAlign.TranscriptionValidator",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."]
            )
        }
        var frames: [Float] = []
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else { continue }
            let sampleCount = dataLength / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            frames.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: sampleCount))
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "SwiftWhisperAlign.TranscriptionValidator",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding."]
            )
        }
        return frames
    }
}
