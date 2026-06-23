// Pure-function implementations for SubtitleEditorSheet's timing tools.
// Lifted out of the sheet so the SwiftUI view file stays under the file-size
// guardrail; the view itself keeps thin wrappers that read its @State, hand
// the snapshot to a tool function, and write the result back to @State.

import Foundation

enum SubtitleEditorTimingTools {

    // Returns the set of cue indices whose SRT blocks overlap the editor selection.
    // When there's no selection (cursor only / zero length), returns all indices —
    // matching the "act on everything when nothing is selected" UX convention used
    // throughout the editor.
    static func selectedCueIndices(cues: [SubtitleCue], selection: NSRange) -> Set<Int> {
        guard selection.length > 0 else {
            return Set(cues.indices)
        }

        var selected = Set<Int>()
        let formatted = SubtitleParser.formatSRT(from: cues)
        let blocks = formatted.components(separatedBy: "\n\n")
        var offset = 0
        for (i, block) in blocks.enumerated() {
            let blockRange = NSRange(location: offset, length: block.utf16.count)
            if NSIntersectionRange(blockRange, selection).length > 0 {
                selected.insert(i)
            }
            // +2 for the "\n\n" separator.
            offset += block.utf16.count + (i < blocks.count - 1 ? 2 : 0)
        }
        return selected
    }

    // Shifts timestamps for cues in `affectedIndices` by `offsetMs`. Cues not in the
    // set pass through unchanged. Negative starts/ends are clamped to 0.
    static func shiftTimes(cues: [SubtitleCue], by offsetMs: Int, affectedIndices: Set<Int>) -> [SubtitleCue] {
        cues.enumerated().map { i, cue in
            guard affectedIndices.contains(i) else { return cue }
            return SubtitleCue(
                index: cue.index,
                startMs: max(0, cue.startMs + offsetMs),
                endMs: max(0, cue.endMs + offsetMs),
                text: cue.text
            )
        }
    }

    // Normalizes timing: extends each cue's end to meet the next cue's start (filling
    // small gaps), and inserts ♪ cues for instrumental gaps longer than `gapThresholdMs`.
    // The returned cues are re-indexed sequentially starting from 1.
    static func normalizeTiming(cues: [SubtitleCue], gapThresholdMs: Int = 10_000) -> [SubtitleCue] {
        guard cues.isEmpty == false else { return [] }

        var normalized: [SubtitleCue] = []

        // Insert ♪ before first cue if the leading gap is large.
        if let first = cues.first, first.startMs > gapThresholdMs {
            normalized.append(SubtitleCue(index: 0, startMs: 0, endMs: first.startMs, text: "♪"))
        }

        for (i, cue) in cues.enumerated() {
            var adjusted = cue

            // Extend first cue backward to 0 if the leading gap is small (no ♪ inserted).
            if i == 0 && cue.startMs > 0 && cue.startMs <= gapThresholdMs {
                adjusted = SubtitleCue(
                    index: adjusted.index,
                    startMs: 0,
                    endMs: adjusted.endMs,
                    text: adjusted.text
                )
            }
            // Small gap before this cue — pull its start back to meet the previous cue's end.
            if let prev = normalized.last, SubtitleParser.isNonSpeechCue(prev.text) == false {
                let gap = adjusted.startMs - prev.endMs
                if gap > 0 && gap <= gapThresholdMs {
                    adjusted = SubtitleCue(
                        index: adjusted.index,
                        startMs: prev.endMs,
                        endMs: adjusted.endMs,
                        text: adjusted.text
                    )
                }
            }
            normalized.append(adjusted)

            // Insert ♪ cue for large gaps.
            if i + 1 < cues.count {
                let gapStart = adjusted.endMs
                let gapEnd = cues[i + 1].startMs
                if gapEnd - gapStart > gapThresholdMs {
                    normalized.append(SubtitleCue(
                        index: 0,
                        startMs: gapStart,
                        endMs: gapEnd,
                        text: "♪"
                    ))
                }
            }
        }

        // Re-index sequentially.
        for i in normalized.indices {
            normalized[i] = SubtitleCue(
                index: i + 1,
                startMs: normalized[i].startMs,
                endMs: normalized[i].endMs,
                text: normalized[i].text
            )
        }

        return normalized
    }

    // Inserts ♪ instrumental markers into the silent stretches around the speech cues — the leading
    // intro, any inter-cue gap longer than `gapThresholdMs`, and the trailing outro up to
    // `durationMs` — WITHOUT touching the existing cues' timings or per-word checkpoints. Used right
    // after a fresh whole-note alignment so the instrumental spans read as ♪ rather than blank.
    // Unlike `normalizeTiming`, it never pulls/extends cue boundaries, so accurate aligned timings
    // (and their checkpoints) are preserved exactly. Re-indexes sequentially from 1.
    static func insertMusicMarkers(cues: [SubtitleCue], durationMs: Int, gapThresholdMs: Int = 5000) -> [SubtitleCue] {
        let speech = cues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        guard speech.isEmpty == false else { return cues }

        var out: [SubtitleCue] = []
        // Leading intro.
        if let first = speech.first, first.startMs > gapThresholdMs {
            out.append(SubtitleCue(index: 0, startMs: 0, endMs: first.startMs, text: "♪"))
        }
        for (i, cue) in speech.enumerated() {
            out.append(cue)   // keep the aligned cue verbatim — timings AND checkpoints intact
            let nextStart = i + 1 < speech.count ? speech[i + 1].startMs : durationMs
            if nextStart - cue.endMs > gapThresholdMs {
                out.append(SubtitleCue(index: 0, startMs: cue.endMs, endMs: nextStart, text: "♪"))
            }
        }

        // Re-index, preserving each cue's checkpoints.
        for i in out.indices {
            out[i] = SubtitleCue(
                index: i + 1,
                startMs: out[i].startMs,
                endMs: out[i].endMs,
                text: out[i].text,
                checkpoints: out[i].checkpoints
            )
        }
        return out
    }

    // Inserts ♪ markers for the REAL music stretches — the gaps BETWEEN the aligner's vocal segments
    // (the energy-VAD regions on the isolated stem). The intro before the first vocal, every gap
    // wider than `minGapMs` between consecutive vocals, and the outro after the last all become ♪;
    // anything covered by a vocal segment never does. This is robust where the cue-time-gap heuristic
    // is not: an alignment-slack gap between two sung lines won't fake an interlude, and a real
    // interlude isn't missed just because a line's timing bled into it. `vocalSegments` are absolute
    // seconds (from AlignmentResult). Falls back to the cue-time heuristic when none are supplied.
    static func insertMusicMarkers(
        cues: [SubtitleCue], durationMs: Int,
        vocalSegments: [(start: Double, end: Double)], minGapMs: Int = 4000
    ) -> [SubtitleCue] {
        let speech = cues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        guard speech.isEmpty == false else { return cues }
        guard vocalSegments.isEmpty == false else {
            return insertMusicMarkers(cues: cues, durationMs: durationMs)   // no VAD info → heuristic
        }

        // Instrumental gaps (ms) = complement of the vocal segments within [0, durationMs].
        let segs = vocalSegments
            .map { (start: max(0, Int(($0.start * 1000).rounded())), end: max(0, Int(($0.end * 1000).rounded()))) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var gaps: [(start: Int, end: Int)] = []
        var cursor = 0
        for s in segs {
            if s.start - cursor >= minGapMs { gaps.append((cursor, s.start)) }
            cursor = max(cursor, s.end)
        }
        if durationMs > 0, durationMs - cursor >= minGapMs { gaps.append((cursor, durationMs)) }

        // Interleave by time: emit each gap just before the first speech cue that begins at/after the
        // gap ends, so the ♪ sits between the pre-gap and post-gap lines. Trailing gaps (outro) flush
        // at the end. A gap that a (mis-timed) line starts inside is skipped to avoid an overlap.
        var out: [SubtitleCue] = []
        var gi = 0
        for cue in speech {
            while gi < gaps.count, gaps[gi].end <= cue.startMs {
                if speech.contains(where: { $0.startMs > gaps[gi].start && $0.startMs < gaps[gi].end }) == false {
                    out.append(SubtitleCue(index: 0, startMs: gaps[gi].start, endMs: gaps[gi].end, text: "♪"))
                }
                gi += 1
            }
            out.append(cue)
        }
        while gi < gaps.count {
            out.append(SubtitleCue(index: 0, startMs: gaps[gi].start, endMs: gaps[gi].end, text: "♪"))
            gi += 1
        }

        for i in out.indices {
            out[i] = SubtitleCue(index: i + 1, startMs: out[i].startMs, endMs: out[i].endMs,
                                 text: out[i].text, checkpoints: out[i].checkpoints)
        }
        return out
    }

    // Ground-truth onset wall. The energy-VAD `vocalSegments` mark exactly where the singer IS
    // singing on the isolated stem, so their complement (any gap ≥ `minGapMs`) is proven silence —
    // and a sung line physically cannot BEGIN there. Anchor-fill's char-rate drift nonetheless
    // sometimes parks a post-interlude line ~20 s early, inside the silence; left there it sweeps
    // "ghostly" over no audio AND suppresses the ♪ (insertMusicMarkers skips a gap a cue starts
    // inside). This pulls every in-gap onset forward to vocal resumption: a run of cues crammed into
    // one gap is repacked across [gapEnd, ceiling], where ceiling is the first cue that legitimately
    // starts at/after the gap (or durationMs). Checkpoints ride along, re-anchored by the onset
    // delta and dropped if pushed past the new end. Cues already in real vocal time are untouched;
    // with no VAD info there's no ground truth, so it's the identity. Run BEFORE insertMusicMarkers
    // so the gap then reads as ♪ rather than as a line over silence.
    static func clampOnsetsToVocal(
        cues: [SubtitleCue], durationMs: Int,
        vocalSegments: [(start: Double, end: Double)], minGapMs: Int = 4000
    ) -> [SubtitleCue] {
        guard vocalSegments.isEmpty == false else { return cues }

        // Instrumental gaps (ms) = complement of the vocal segments — SAME computation as
        // insertMusicMarkers, so a cue this leaves outside every gap is exactly one it won't suppress.
        let segs = vocalSegments
            .map { (start: max(0, Int(($0.start * 1000).rounded())), end: max(0, Int(($0.end * 1000).rounded()))) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var gaps: [(start: Int, end: Int)] = []
        var cursor = 0
        for s in segs {
            if s.start - cursor >= minGapMs { gaps.append((cursor, s.start)) }
            cursor = max(cursor, s.end)
        }
        if durationMs > 0, durationMs - cursor >= minGapMs { gaps.append((cursor, durationMs)) }
        guard gaps.isEmpty == false else { return cues }

        // The gap a given onset falls strictly inside, if any (boundaries are vocal, not gap).
        func gapContaining(_ ms: Int) -> (start: Int, end: Int)? {
            gaps.first { ms > $0.start && ms < $0.end }
        }

        var out = cues
        var i = 0
        while i < out.count {
            guard SubtitleParser.isNonSpeechCue(out[i].text) == false,
                  let gap = gapContaining(out[i].startMs) else { i += 1; continue }

            // Consecutive run of speech cues whose onsets all fall inside THIS gap.
            var j = i
            while j < out.count,
                  SubtitleParser.isNonSpeechCue(out[j].text) == false,
                  let g = gapContaining(out[j].startMs), g.start == gap.start {
                j += 1
            }

            // Repack [i, j) across [gapEnd, ceiling]. ceiling = the next cue's onset (the first line
            // that legitimately resumes after the gap) or durationMs for a trailing cram.
            let count = j - i
            let ceiling = j < out.count ? max(gap.end, out[j].startMs) : max(gap.end, durationMs)
            let slot = max(0, ceiling - gap.end) / count   // even split (see note below)
            for k in i..<j {
                let newStart = gap.end + slot * (k - i)
                let newEnd = (k + 1 < j) ? gap.end + slot * (k - i + 1) : ceiling
                out[k] = reanchorCue(out[k], newStart: newStart, newEnd: max(newStart + 50, newEnd))
            }
            i = j
        }
        return out
    }

    // Moves a cue to [newStart, newEnd], re-anchoring its checkpoints by the start delta and
    // dropping any that the move pushes outside the new bounds (mirrors mergeCheckpoints' clamping).
    private static func reanchorCue(_ cue: SubtitleCue, newStart: Int, newEnd: Int) -> SubtitleCue {
        let delta = newStart - cue.startMs
        let cps = cue.checkpoints.compactMap { c -> CueCharTiming? in
            let t = c.timeMs + delta
            guard t >= newStart, t <= newEnd else { return nil }
            return CueCharTiming(timeMs: t, charOffsetInCue: c.charOffsetInCue, charLength: c.charLength)
        }
        return SubtitleCue(index: cue.index, startMs: newStart, endMs: newEnd,
                           text: cue.text, checkpoints: cps)
    }

    // Carries per-word checkpoints across a lossy text round-trip (the SRT editor can only
    // represent index/timecodes/text, never checkpoints). For each cue in `edited`, finds the
    // earliest not-yet-consumed cue in `previous` with byte-identical text and adopts its
    // checkpoints, re-anchored by the start-time delta (newStart − oldStart) and clamped to the
    // edited cue's [startMs, endMs] — checkpoints a shrink pushed out of bounds are dropped.
    //
    // Matching is by text CONTENT in order, not by index, so it survives inserts, deletes,
    // splits, and merges; duplicate identical lines (chorus refrains) are paired front-to-back in
    // time order. A cue whose text actually CHANGED finds no identical predecessor and keeps its
    // own (normally empty) checkpoints — the old character offsets no longer describe the new text,
    // so dropping them is correct: that line needs a fresh word-sweep. Cues that already carry
    // checkpoints, and ♪/non-speech cues, are left untouched.
    static func mergeCheckpoints(into edited: [SubtitleCue], from previous: [SubtitleCue]) -> [SubtitleCue] {
        // Bucket predecessor cues that actually have timing by exact text, each bucket in time order
        // so identical lines are consumed earliest-first to mirror the (also time-ordered) edited list.
        var byText: [String: [SubtitleCue]] = [:]
        for cue in previous where cue.checkpoints.isEmpty == false {
            byText[cue.text, default: []].append(cue)
        }
        for key in byText.keys {
            byText[key]?.sort { $0.startMs < $1.startMs }
        }

        return edited.map { cue in
            guard cue.checkpoints.isEmpty,
                  SubtitleParser.isNonSpeechCue(cue.text) == false,
                  var bucket = byText[cue.text], bucket.isEmpty == false else {
                return cue
            }
            let source = bucket.removeFirst()
            byText[cue.text] = bucket

            let delta = cue.startMs - source.startMs
            let reanchored = source.checkpoints.compactMap { checkpoint -> CueCharTiming? in
                let shifted = checkpoint.timeMs + delta
                guard shifted >= cue.startMs, shifted <= cue.endMs else { return nil }
                return CueCharTiming(
                    timeMs: shifted,
                    charOffsetInCue: checkpoint.charOffsetInCue,
                    charLength: checkpoint.charLength
                )
            }
            var updated = cue
            updated.checkpoints = reanchored
            return updated
        }
    }

    // Replaces each mismatched cue's text with the corresponding note text, preserving
    // timestamps. ♪ cues are never rewritten (their text is metadata, not transcript).
    // `highlightRanges` aligns 1:1 with `cues`; entries are nil for cues that don't map
    // to a note line.
    static func normalizeCueText(cues: [SubtitleCue], highlightRanges: [NSRange?], noteText: String) -> [SubtitleCue] {
        var result = cues
        for index in result.indices {
            guard SubtitleParser.isNonSpeechCue(result[index].text) == false else { continue }
            guard index < highlightRanges.count,
                  let range = highlightRanges[index],
                  let swiftRange = Range(range, in: noteText) else { continue }
            let noteLineText = String(noteText[swiftRange])
            if noteLineText != result[index].text {
                result[index] = SubtitleCue(
                    index: result[index].index,
                    startMs: result[index].startMs,
                    endMs: result[index].endMs,
                    text: noteLineText
                )
            }
        }
        return result
    }
}
