// OnDeviceLyricAligner.swift
// App-side entry point for on-device lyric alignment: wraps SwiftWhisperAlign's CTCForcedAligner
// with the note's line filtering and a background-task assertion.

import Foundation
import SwiftWhisperAlign
#if canImport(UIKit)
import UIKit
#endif

enum OnDeviceLyricAligner {

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
            // Vocal isolation runs on the GPU, which iOS refuses to a backgrounded app: park the
            // separator between chunks rather than letting the next one be aborted mid-flight.
            waitUntilReady: { await AlignmentForegroundGuard.waitUntilForeground() },
            onProgress: nil,
            onStage: onStage,
            onSegment: onSegment
        )
        AppLog.info(.audioAlignment, "alignment complete: \(result.lines.count) lines")
        return result
    }
}
