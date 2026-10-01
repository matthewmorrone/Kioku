import Foundation

// Resolves "which audio time-range corresponds to this breakdown line?" by text-matching
// SongLine.original against SubtitleCue.text, then tightens each match's raw cue boundary
// against the cue's own per-character alignment checkpoints when available — see
// tightenedRange. SongLine has no timing of its own — timing lives in the cues — so the only
// join key is the line text. We walk both sequences with a cursor (cues run forward through
// the song) so a chorus repeating "サヨナラ" matches its successive occurrences instead of all
// snapping to the first cue.
//
// Matching is whitespace-normalized equality, falling back to containment: a line with no equal
// cue ahead of the cursor takes the next cue whose text contains it. The fallback covers lines the
// LLM shortened on the user's instruction (a breakdown note like "ignore everything in
// parentheses" drops "(セーラースマイル)" from line.original while the cue keeps it). Lines that
// match no cue either way don't get a playback range — the UI hides their play button.
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
        let originalByIndex = Dictionary(lines.map { ($0.index, $0.original) }, uniquingKeysWith: { first, _ in first })
        var result: [Int: (startMs: Int, endMs: Int)] = [:]
        for (position, match) in matches.enumerated() {
            let cue = cues[match.cueIndex]
            let nextCue = position + 1 < matches.count ? cues[matches[position + 1].cueIndex] : nil
            let range = tightenedRange(for: cue, nextCue: nextCue)
            result[match.lineIndex] = narrowed(range, toLine: originalByIndex[match.lineIndex] ?? "", in: cue)
        }
        return result
    }

    // Narrows a cue's range to the stretch of the cue the line's own text covers, so a line
    // matched by containment doesn't play what the LLM left out of it (a dropped
    // "(セーラースマイル)" backing vocal): from the onset of the line's first character to the
    // onset of the first character after it. A line equal to its cue, a cue without
    // checkpoints, or a line not found verbatim in the cue text keeps `range` unchanged.
    private static func narrowed(
        _ range: (startMs: Int, endMs: Int),
        toLine original: String,
        in cue: SubtitleCue
    ) -> (startMs: Int, endMs: Int) {
        let lineText = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = (cue.text as NSString).range(of: lineText)
        guard lineText.isEmpty == false, found.location != NSNotFound, cue.checkpoints.isEmpty == false else {
            return range
        }
        let checkpoints = cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
        let lineEnd = found.location + found.length
        let startOnset = checkpoints.last(where: { $0.charOffsetInCue <= found.location })?.timeMs ?? range.startMs
        let endOnset = checkpoints.first(where: { $0.charOffsetInCue >= lineEnd })?.timeMs ?? range.endMs
        let startMs = max(range.startMs, startOnset)
        let endMs = min(range.endMs, endOnset)
        return endMs > startMs ? (startMs, endMs) : range
    }

    // Returns line.index → the cue that line matched, for cutting per-word snippets out of the
    // cue's own alignment checkpoints (SongWordClipLocator). Same forward-cursor matching as
    // computeRanges, so both maps always agree on which cue a line is.
    static func matchedCues(
        lines: [SongLine],
        cues: [SubtitleCue]
    ) -> [Int: SubtitleCue] {
        var result: [Int: SubtitleCue] = [:]
        for match in matchedCueIndices(lines: lines, cues: cues) {
            result[match.lineIndex] = cues[match.cueIndex]
        }
        return result
    }

    // Walks lines and cues in parallel, pairing each line to the next cue (from a
    // forward-only cursor) whose text matches. Split out of computeRanges so the tightening
    // pass below can see each match's NEXT match too (needed for the trailing-edge bound).
    // An equal cue anywhere ahead wins over a containing one, so the looser fallback can't pull
    // a short line onto an earlier, longer cue that merely includes it.
    private static func matchedCueIndices(
        lines: [SongLine],
        cues: [SubtitleCue]
    ) -> [(lineIndex: Int, cueIndex: Int)] {
        var matches: [(lineIndex: Int, cueIndex: Int)] = []
        var cursor = 0
        let normCues = cues.map { normalize($0.text) }

        for line in lines {
            let normLine = normalize(line.original)
            guard normLine.isEmpty == false, cursor < normCues.count else { continue }

            let remaining = cursor..<normCues.count
            let match = remaining.first { normCues[$0] == normLine }
                ?? remaining.first { normCues[$0].contains(normLine) }
            if let match {
                matches.append((lineIndex: line.index, cueIndex: match))
                cursor = match + 1
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
