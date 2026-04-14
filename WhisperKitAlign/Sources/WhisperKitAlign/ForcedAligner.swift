// ForcedAligner.swift
// Public entry point for the forced-alignment pipeline.
// Wraps ForcedAlignmentProvider and produces SRT output.

import Foundation

// Orchestrates forced alignment of lyric lines against audio and produces SRT.
public struct ForcedAligner {
    private let modelURL: URL

    // modelURL must point to a GGML .bin Whisper model file.
    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    // Aligns lyric lines to audio and returns the result with timestamps.
    // cancellationCheck: polled during inference; return true to abort.
    // onProgress: called with 0–1 fraction during Whisper inference.
    // onSegment: called each time a segment completes with partial alignment results.
    public func align(
        input: AlignmentInput,
        cancellationCheck: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: (([AlignedLine]) -> Void)? = nil
    ) async throws -> AlignmentResult {
        let provider = ForcedAlignmentProvider(modelURL: modelURL)
        return try await provider.align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onSegment: onSegment
        )
    }

    // Aligns and writes the result as SRT to the given file URL.
    public func alignAndWrite(
        input: AlignmentInput,
        outputURL: URL,
        cancellationCheck: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: (([AlignedLine]) -> Void)? = nil
    ) async throws {
        let result = try await align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onSegment: onSegment
        )
        try SRTWriter.write(result, to: outputURL)
    }

    // Aligns and returns the SRT text as a string.
    public func alignToSRT(
        input: AlignmentInput,
        cancellationCheck: (() -> Bool)? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onSegment: (([AlignedLine]) -> Void)? = nil
    ) async throws -> String {
        let result = try await align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: onProgress,
            onSegment: onSegment
        )
        return SRTWriter.write(result)
    }
}
