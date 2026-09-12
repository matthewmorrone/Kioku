import AVFoundation
import Foundation
import SwiftWhisperAlign

// The one way lyrics get timed against a song: a single forced-alignment pass over the whole
// track from the note text (romanized per line by the caller), then ♪ markers over the
// instrumental stretches. Existing cues are
// never consulted — a full pass takes seconds, so re-aligning everything is cheaper and more
// predictable than keeping old timings as anchors and patching the gaps between them.
enum WholeSongAlignment {
    // Aligns `lyrics` (one line per cue) to the audio and returns the complete cue list: speech
    // cues carrying per-character karaoke checkpoints, plus ♪ markers wherever the stem's vocal
    // regions leave a gap. `durationMs` is read from the file when the caller doesn't have it.
    static func cues(
        audioURL: URL,
        lyrics: String,
        romanize: (String) -> [RomanizedSpan],
        durationMs knownDurationMs: Int? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        let result = try await OnDeviceLyricAligner.alignDetailed(
            audioURL: audioURL,
            lyrics: lyrics,
            romanize: romanize,
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

        return insertingMusicMarkers(into: cues, durationMs: durationMs)
    }

    // A gap at least this long between consecutive lines (or before the first / after the last)
    // is an instrumental stretch and gets a ♪ cue.
    static let interludeMinMs = 4000

    // Inserts ♪ cues into the gaps between aligned lines and renumbers the result.
    static func insertingMusicMarkers(into cues: [SubtitleCue], durationMs: Int) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var lastEnd = 0
        for cue in cues {
            if cue.startMs - lastEnd >= interludeMinMs {
                out.append(SubtitleCue(index: 0, startMs: lastEnd, endMs: cue.startMs, text: "♪"))
            }
            out.append(cue)
            lastEnd = max(lastEnd, cue.endMs)
        }
        if durationMs - lastEnd >= interludeMinMs {
            out.append(SubtitleCue(index: 0, startMs: lastEnd, endMs: durationMs, text: "♪"))
        }
        for i in out.indices { out[i].index = i + 1 }
        return out
    }
}
