// Post-processing for the whole-song alignment result: ♪ markers over the instrumental
// stretches, and the onset clamp that keeps a line from drifting into a proven gap.

import Foundation

enum SubtitleTimingTools {

    // Inserts ♪ markers for the REAL music stretches — the gaps BETWEEN the aligner's vocal segments
    // (the energy-VAD regions on the isolated stem). The intro before the first vocal, every gap
    // wider than `minGapMs` between consecutive vocals, and the outro after the last all become ♪;
    // anything covered by a vocal segment never does. This is robust where the cue-time-gap heuristic
    // is not: an alignment-slack gap between two sung lines won't fake an interlude, and a real
    // interlude isn't missed just because a line's timing bled into it. `vocalSegments` are absolute
    // seconds (from AlignmentResult). With no vocal segments, cues come back time-sorted, no ♪.
    static func insertMusicMarkers(
        cues: [SubtitleCue], durationMs: Int,
        vocalSegments: [(start: Double, end: Double)], minGapMs: Int = 4000
    ) -> [SubtitleCue] {
        // Sorted by start time so the gap-interleave below (which walks speech in array order,
        // emitting each ♪ before the first cue that starts at/after the gap ends) matches time order
        // even when the aligner emitted a line out of monotonic order.
        let speech = cues
            .filter { SubtitleParser.isNonSpeechCue($0.text) == false }
            .sorted { $0.startMs < $1.startMs }
        guard speech.isEmpty == false else { return cues }
        guard vocalSegments.isEmpty == false else { return speech }

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
    // dropping any that the move pushes outside the new bounds (dropped if the move pushes them out of bounds).
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
}
