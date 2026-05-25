// Decodes an audio file to 16 kHz mono 32-bit float PCM — the format
// whisper.cpp requires for its input frames. Extracted from
// ForcedAlignmentProvider so the orchestrator file stays under the 800-line
// guardrail; the AVFoundation buffer-reading boilerplate isn't a provider
// responsibility, just a precondition the provider relies on.

import AVFoundation
import CoreMedia
import Foundation

enum WhisperAudioFrameDecoder {

    // Decodes audio to 16 kHz mono 32-bit float PCM — the format whisper.cpp requires.
    static func decode(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No audio track found in file."]
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
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader."]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."]
            )
        }

        var frames: [Float] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
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
                domain: "SwiftWhisperAlign.ForcedAlignment",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed while decoding."]
            )
        }

        return frames
    }
}
