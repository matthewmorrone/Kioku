import AVFoundation
import Foundation
import SwiftWhisperAlign

// The one way lyrics get timed against a song: a single forced-alignment pass over the whole
// track from the note text, then ♪ markers over the instrumental stretches. Existing cues are
// never consulted — a full pass takes seconds, so re-aligning everything is cheaper and more
// predictable than keeping old timings as anchors and patching the gaps between them.
enum WholeSongAlignment {
    // Aligns `lyrics` (one line per cue) to the audio and returns the complete cue list: speech
    // cues carrying per-character karaoke checkpoints, plus ♪ markers wherever the stem's vocal
    // regions leave a gap. `durationMs` is read from the file when the caller doesn't have it.
    static func cues(
        audioURL: URL,
        lyrics: String,
        durationMs knownDurationMs: Int? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        let result = try await OnDeviceLyricAligner.alignDetailed(
            audioURL: audioURL,
            lyrics: lyrics,
            cancellationCheck: cancellationCheck,
            onStage: onStage
        )
        guard result.lines.isEmpty == false else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Alignment produced no aligned lines."]
            )
        }

        let durationMs: Int
        if let knownDurationMs, knownDurationMs > 0 {
            durationMs = knownDurationMs
        } else if let seconds = try? await AVURLAsset(url: audioURL).load(.duration), seconds.isNumeric {
            durationMs = Int(CMTimeGetSeconds(seconds) * 1000)
        } else {
            durationMs = 0
        }

        // Cues straight from the structured result, folding each line's aligner units into
        // per-character checkpoints (UTF-16 offsets map 1:1 onto CueCharTiming).
        var cues: [SubtitleCue] = []
        for (i, line) in result.lines.enumerated() {
            let startMs = max(0, Int((line.start * 1000).rounded()))
            var endMs = max(startMs + 50, Int((line.end * 1000).rounded()))   // ≥50 ms cue
            if durationMs > 0 { endMs = min(endMs, durationMs) }
            let tokens = i < result.lineTokens.count ? result.lineTokens[i] : []
            let checkpoints = tokens
                .map { token in
                    CueCharTiming(
                        timeMs: max(0, Int((token.start * 1000).rounded())),
                        charOffsetInCue: token.charOffsetUTF16,
                        charLength: token.charLengthUTF16
                    )
                }
                .sorted { $0.timeMs < $1.timeMs }
            cues.append(SubtitleCue(index: i + 1, startMs: startMs, endMs: endMs,
                                    text: line.text, checkpoints: checkpoints))
        }

        // Pull any line whose onset drifted into a proven instrumental gap forward to where the
        // vocal actually resumes, so it neither sweeps over silence nor suppresses the gap's ♪.
        let clamped = SubtitleTimingTools.clampOnsetsToVocal(
            cues: cues, durationMs: durationMs, vocalSegments: result.vocalSegments
        )
        // ♪ markers over the intro, breaks, and outro — driven by the stem's vocal regions, so a
        // marker only appears where the singer truly isn't singing.
        return SubtitleTimingTools.insertMusicMarkers(
            cues: clamped, durationMs: durationMs, vocalSegments: result.vocalSegments
        )
    }
}
