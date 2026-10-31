import AVFoundation
import Foundation
import LyricAlignment

// The one way lyrics get timed against a song: a single forced-alignment pass over the whole
// track from the note text (romanized per line by the caller), then ♪ markers over the
// instrumental stretches. Existing cues are
// never consulted — a full pass takes seconds, so re-aligning everything is cheaper and more
// predictable than keeping old timings as anchors and patching the gaps between them.
enum WholeSongAlignment {
    // Aligns `lyrics` (one line per cue) to the audio and returns the complete cue list: speech
    // cues carrying per-character karaoke checkpoints, plus ♪ markers wherever the stem's vocal
    // regions leave a gap. `durationMs` is read from the file when the caller doesn't have it.
    // `issues` are the places the aligner found the lyrics and the singing disagree, and `sungOrder`
    // the order the lines seem to be sung in when there are issues and it isn't the note's.
    static func cues(
        audioURL: URL,
        lyrics: String,
        romanize: @escaping @Sendable (String) -> [RomanizedSpan],
        durationMs knownDurationMs: Int? = nil,
        cancellationCheck: (@Sendable () -> Bool)? = nil,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> (cues: [SubtitleCue], issues: [LyricAlignmentIssue], sungOrder: [LyricSungOrderEntry]?) {
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
        } else if let seconds = AudioFileDuration.seconds(of: audioURL) {
            durationMs = Int(seconds * 1000)
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
                        charLength: token.charLengthUTF16,
                        confidence: token.confidence
                    )
                }
                .sorted { $0.timeMs < $1.timeMs }
            cues.append(SubtitleCue(index: i + 1, startMs: startMs, endMs: endMs,
                                    text: line.text, checkpoints: checkpoints))
        }

        let issues = result.mismatches.enumerated().map { offset, mismatch in
            // Singing at the song's end goes after the last line; otherwise new lyrics go before the
            // line sung next, or after the stretched line.
            let anchor = mismatch.lineIndex ?? (result.lines.isEmpty ? nil : result.lines.count - 1)
            let anchorLine = anchor.flatMap { $0 < cues.count ? cues[$0] : nil }
            return LyricAlignmentIssue(
                id: offset,
                kind: mismatch.kind,
                startMs: max(0, Int((mismatch.start * 1000).rounded())),
                endMs: max(0, Int((mismatch.end * 1000).rounded())),
                lineText: mismatch.kind == .stretchedLine ? anchorLine?.text : nil,
                anchorStartMs: anchorLine?.startMs,
                insertsBeforeAnchor: mismatch.kind == .unmatchedSinging && mismatch.lineIndex != nil
            )
        }
        let sungOrder = result.sungOrder?.map { entry in
            LyricSungOrderEntry(
                startMs: max(0, Int((entry.start * 1000).rounded())),
                endMs: max(0, Int((entry.end * 1000).rounded())),
                lineText: entry.lineIndex.flatMap { $0 < result.lines.count ? result.lines[$0].text : nil }
            )
        }
        return (insertingMusicMarkers(into: cues, durationMs: durationMs), issues, sungOrder)
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
