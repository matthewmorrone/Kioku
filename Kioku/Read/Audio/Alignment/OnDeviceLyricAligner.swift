// OnDeviceLyricAligner.swift
// App-side entry point for on-device lyric alignment: wraps SwiftWhisperAlign's CTCForcedAligner
// with the note's line filtering and a background-task assertion. Also resolves the best
// downloaded ggml Whisper model, which the transcription feature shares.

import Foundation
import SwiftWhisperAlign
#if canImport(UIKit)
import UIKit
#endif

enum OnDeviceLyricAligner {

    // Returns the best available downloaded GGML model URL, preferring
    // higher-quality models. Returns nil if no model has been downloaded yet.
    static func bestAvailableModelURL() -> URL? {
        let dir = WhisperModelManager.modelsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            AppLog.error(.audioAlignment, "models directory not found at \(dir.path)")
            return nil
        }

        let preferenceOrder = ["ggml-medium.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin"]
        let binFiles = files.filter { $0.hasSuffix(".bin") }
        AppLog.info(.audioAlignment, "found \(binFiles.count) model(s): \(binFiles.sorted().joined(separator: ", "))")
        guard binFiles.isEmpty == false else { return nil }

        for preferred in preferenceOrder {
            if binFiles.contains(preferred) {
                AppLog.info(.audioAlignment, "selected model: \(preferred)")
                return dir.appendingPathComponent(preferred)
            }
        }
        let fallback = binFiles.sorted().first!
        AppLog.info(.audioAlignment, "selected model (fallback): \(fallback)")
        return dir.appendingPathComponent(fallback)
    }

    // Force-aligns the lyric lines to the audio and returns the structured result: per-line
    // timings and per-span sub-line checkpoints (for the per-mora karaoke sweep). `romanize`
    // supplies each line's romanized spans — the aligner reads romaji, not Japanese.
    static func alignDetailed(
        audioURL: URL,
        lyrics: String,
        romanize: (String) -> [RomanizedSpan],
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil,
        onSegment: (@Sendable ([SwiftWhisperAlign.AlignedLine]) -> Void)? = nil
    ) async throws -> SwiftWhisperAlign.AlignmentResult {
        let lines = lyrics
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard lines.isEmpty == false else {
            throw NSError(
                domain: "Kioku.OnDeviceAlignment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No lyric lines to align. Add lyrics to the note before generating subtitles."]
            )
        }

        AppLog.info(.audioAlignment, "force-aligning \(lines.count) line(s) via CTC")
        let input = AlignmentInput(audioURL: audioURL, lines: lines, romanization: lines.map(romanize))

        #if canImport(UIKit)
        let bg = BackgroundTaskHolder.begin("kioku.lyric-alignment")
        defer { bg.endDetached() }
        #endif

        let result = try await CTCForcedAligner().align(
            input: input,
            cancellationCheck: cancellationCheck,
            onProgress: nil,
            onStage: onStage,
            onSegment: onSegment
        )
        AppLog.info(.audioAlignment, "alignment complete: \(result.lines.count) lines")
        return result
    }
}
