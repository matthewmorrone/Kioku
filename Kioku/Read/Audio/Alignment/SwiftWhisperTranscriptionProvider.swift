// SwiftWhisperTranscriptionProvider.swift
// Bridges SwiftWhisper to the AlignmentSegment type expected by LineAligner.
//
// SwiftWhisper.Segment uses startTime/endTime in milliseconds (Int).
// AlignmentSegment uses start/end in seconds (Double).
//
// Audio decoding uses AVAssetReader to resample the source file to
// 16 kHz mono float PCM — the format whisper.cpp requires.
//
// Live progress is surfaced via two optional callbacks:
//   onProgress(0–1)       — encoder progress fraction
//   onSegment(text)       — called on main queue each time a new segment is decoded

import AVFoundation
import SwiftWhisper

// Transcribes audio from a file URL using a GGML Whisper model
// and returns segments as AlignmentSegments with second-based timestamps.
final class SwiftWhisperTranscriptionProvider {
    private let modelURL: URL

    // modelURL must point to a GGML .bin file (from WhisperModelManager).
    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    // Decodes audio to 16 kHz mono float PCM, runs Whisper inference,
    // and converts the resulting segments to AlignmentSegment values.
    // onProgress: called on main queue with a 0–1 fraction as inference advances.
    // onSegment: called on main queue with each new decoded segment's text.
    func transcribe(
        url: URL,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: ((String) -> Void)? = nil
    ) async throws -> [AlignmentSegment] {
        let frames = try await decodeAudioFrames(from: url)
        guard frames.isEmpty == false else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Audio decoded to zero frames — the file may be silent or unsupported."]
            )
        }

        let whisper = Whisper(fromFileURL: modelURL)

        // Wire up the delegate only when callers want live updates,
        // to avoid retaining the delegate object unnecessarily.
        var delegate: AlignmentProgressDelegate?
        if onProgress != nil || onSegment != nil {
            let d = AlignmentProgressDelegate(onProgress: onProgress, onSegment: onSegment)
            whisper.delegate = d
            delegate = d // retain until transcription completes
        }

        let segments = try await whisper.transcribe(audioFrames: frames)

        // Discard delegate now that inference is done.
        _ = delegate

        return segments.map {
            AlignmentSegment(
                text: $0.text,
                start: Double($0.startTime) / 1000.0,
                end: Double($0.endTime) / 1000.0
            )
        }
    }

    // Reads the audio asset with AVAssetReader and converts it to the
    // 16 kHz mono 32-bit float PCM array that whisper.cpp expects.
    // This mirrors the approach used in ReadView+AudioTranscriptionChunking
    // for speech activity detection.
    private func decodeAudioFrames(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "No audio track found in the selected file."]
            )
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:              kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey:      true,
            AVLinearPCMBitDepthKey:     32,
            AVLinearPCMIsBigEndianKey:  false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey:            16_000,
            AVNumberOfChannelsKey:      1
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader for Whisper decoding."]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."]
            )
        }

        var frames: [Float] = []

        // Read sample buffers until the asset is exhausted.
        // Explicit condition avoids unbounded while-true per project loop-safety rule.
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else {
                continue
            }

            let sampleCount = dataLength / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            frames.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: sampleCount))
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding frames."]
            )
        }

        return frames
    }
}

// Forwards SwiftWhisper delegate callbacks to the progress and segment closures.
// Must be a class because WhisperDelegate requires AnyObject.
private final class AlignmentProgressDelegate: WhisperDelegate {
    private let onProgress: ((Double) -> Void)?
    private let onSegment: ((String) -> Void)?

    init(onProgress: ((Double) -> Void)?, onSegment: ((String) -> Void)?) {
        self.onProgress = onProgress
        self.onSegment = onSegment
    }

    // Forwards inference progress fraction to the caller. Already dispatched to main by SwiftWhisper.
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        onProgress?(progress)
    }

    // Forwards each newly decoded segment's text to the caller. Already dispatched to main by SwiftWhisper.
    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        let text = segments.map(\.text).joined()
        if text.isEmpty == false {
            onSegment?(text)
        }
    }

    // No action needed — final segments are returned by the async transcribe call.
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}

    // Errors are surfaced through the async throw path; no action needed here.
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {}
}
