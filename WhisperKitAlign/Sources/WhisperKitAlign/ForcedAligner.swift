// ForcedAligner.swift
// Main entry point. WhisperKit is injected via TranscriptionProvider
// so the core logic is testable without a real model.

import Foundation

public protocol TranscriptionProvider {
    func transcribe(url: URL, language: String) async throws -> [TranscriptionSegment]
}

public struct ForcedAligner {
    private let provider: TranscriptionProvider
    public init(provider: TranscriptionProvider) { self.provider = provider }

    public func align(input: AlignmentInput) async throws -> AlignmentResult {
        let segments    = try await provider.transcribe(url: input.audioURL, language: input.language)
        let alignedLines = LineAligner.align(lines: input.lines, segments: segments)
        return AlignmentResult(lines: alignedLines)
    }

    public func alignAndWrite(input: AlignmentInput, outputURL: URL) async throws {
        try SRTWriter.write(try await align(input: input), to: outputURL)
    }
}

// WhisperKit production provider — compiled only on Apple platforms.
#if canImport(WhisperKit)
import WhisperKit

public final class WhisperKitProvider: TranscriptionProvider {
    private let whisperKit: WhisperKit

    public init(modelFolder: String? = nil) async throws {
        self.whisperKit = try await WhisperKit(WhisperKitConfig(modelFolder: modelFolder))
    }

    public func transcribe(url: URL, language: String) async throws -> [TranscriptionSegment] {
        let options = DecodingOptions(language: language,
                                     withoutTimestamps: false,
                                     wordTimestamps: false)
        guard let results = try await whisperKit.transcribe(audioPath: url.path,
                                                           decodeOptions: options)
        else { return [] }
        return results.flatMap { $0.segments }.map {
            TranscriptionSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
        }
    }
}
#endif
