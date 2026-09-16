import Foundation

// Resolves "which audio time-range corresponds to this breakdown line?" by text-matching
// SongLine.original against SubtitleCue.text, then tightens each match's raw cue boundary
// against the cue's own per-character alignment checkpoints when available — see
// tightenedRange. SongLine has no timing of its own — timing lives in the cues — so the only
// join key is the line text. We walk both sequences with a cursor (cues run forward through
// the song) so a chorus repeating "サヨナラ" matches its successive occurrences instead of all
// snapping to the first cue.
//
// Matching is whitespace-normalized equality. SRT lyric files in practice contain the
// same characters as the breakdown's line.original (the LLM is fed the verbatim note
// text), so equality after whitespace strip is enough for the common case. Lines that
// don't match any cue simply don't get a playback range — the UI hides their play button.
enum SongLineCueMatcher {

    // Returns line.index → (startMs, endMs) for lines whose text matches a single cue, each
    // range tightened against alignment checkpoints when the note went through the
    // forced-alignment flow (empty checkpoints — plain SRT import or ASR transcription —
    // leaves the match's raw cue boundary unchanged). Lines with no match are absent from the
    // map (caller treats that as "no audio range").
    static func computeRanges(
        lines: [SongLine],
        cues: [SubtitleCue]
    ) -> [Int: (startMs: Int, endMs: Int)] {
        let matches = matchedCueIndices(lines: lines, cues: cues)
        var result: [Int: (startMs: Int, endMs: Int)] = [:]
        for (position, match) in matches.enumerated() {
            let cue = cues[match.cueIndex]
            let nextCue = position + 1 < matches.count ? cues[matches[position + 1].cueIndex] : nil
            result[match.lineIndex] = tightenedRange(for: cue, nextCue: nextCue)
        }
        return result
    }

    // Walks lines and cues in parallel, pairing each line to the next cue (from a
    // forward-only cursor) whose text matches. Split out of computeRanges so the tightening
    // pass below can see each match's NEXT match too (needed for the trailing-edge bound).
    private static func matchedCueIndices(
        lines: [SongLine],
        cues: [SubtitleCue]
    ) -> [(lineIndex: Int, cueIndex: Int)] {
        var matches: [(lineIndex: Int, cueIndex: Int)] = []
        var cursor = 0

        for line in lines {
            let normLine = normalize(line.original)
            guard normLine.isEmpty == false else { continue }

            var i = cursor
            while i < cues.count {
                let normCue = normalize(cues[i].text)
                if normCue.isEmpty == false && normCue == normLine {
                    matches.append((lineIndex: line.index, cueIndex: i))
                    cursor = i + 1
                    break
                }
                i += 1
            }
        }

        return matches
    }

    // Tightens a cue's raw boundary using real alignment timestamps, never expanding it:
    //   - Leading edge: the cue's own first checkpoint — the aligner's directly-measured onset
    //     of this line's first character/mora — when it falls later than the raw cue start.
    //   - Trailing edge: the NEXT matched cue's first checkpoint (its raw startMs when it has
    //     no checkpoints) — the measured onset of the *next* line's singing is the only real
    //     signal for "where this line's audio should stop": checkpoints mark onsets only, so
    //     this cue's own last checkpoint has no matching end-of-character timestamp to read.
    // A cue with no checkpoints (never aligned) or no next match (the last line) falls back to
    // its own raw boundary unchanged on that edge.
    private static func tightenedRange(
        for cue: SubtitleCue,
        nextCue: SubtitleCue?
    ) -> (startMs: Int, endMs: Int) {
        var startMs = cue.startMs
        if let firstCheckpoint = cue.checkpoints.min(by: { $0.timeMs < $1.timeMs }) {
            startMs = min(max(cue.startMs, firstCheckpoint.timeMs), cue.endMs)
        }

        var endMs = cue.endMs
        if let nextCue {
            let nextOnsetMs = nextCue.checkpoints.min(by: { $0.timeMs < $1.timeMs })?.timeMs ?? nextCue.startMs
            endMs = min(endMs, max(nextOnsetMs, startMs + 1))
        }

        return (startMs: startMs, endMs: max(startMs + 1, endMs))
    }

    // Whitespace strip for line/cue comparison. Drops spaces, tabs, and newlines, joining
    // the remainder. Keeps every other Unicode scalar so kana and kanji compare verbatim.
    // Internal (not private) — also used by LyricsView+BreakdownGist to key breakdown gists
    // by the same normalized cue text, so the two text-matching call sites can't drift apart.
    static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined()
    }
}
