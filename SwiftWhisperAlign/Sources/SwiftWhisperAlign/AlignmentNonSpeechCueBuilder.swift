// Inserts ♪ cues into the aligned line list for the windows between lyric
// lines that contain real audible non-speech (vs silence). Extracted from
// ForcedAlignmentProvider so the orchestrator file stays under the 800-line
// guardrail; nothing here reads provider instance state.

import Foundation

enum AlignmentNonSpeechCueBuilder {

    // Inserts ♪ cues for gaps between lyric lines that exceed the threshold.
    static func insertNonSpeechCues(
        lyricLines: [AlignedLine],
        audioDuration: Double,
        gapThreshold: Double,
        nonSpeech: NonSpeechDetector
    ) -> [AlignedLine] {
        var combined: [AlignedLine] = []

        // Gap before first lyric line.
        if let first = lyricLines.first, first.start > gapThreshold,
           let interval = audibleInterval(start: 0, end: first.start, gapThreshold: gapThreshold, nonSpeech: nonSpeech) {
            combined.append(AlignedLine(text: "♪", start: interval.start, end: interval.end))
        }

        for (i, line) in lyricLines.enumerated() {
            combined.append(line)

            // Gap between consecutive lines.
            if i + 1 < lyricLines.count {
                let gap = lyricLines[i + 1].start - line.end
                if gap > gapThreshold,
                   let interval = audibleInterval(start: line.end, end: lyricLines[i + 1].start, gapThreshold: gapThreshold, nonSpeech: nonSpeech) {
                    combined.append(AlignedLine(text: "♪", start: interval.start, end: interval.end))
                }
            }
        }

        // Gap after last lyric line.
        if let last = lyricLines.last, audioDuration - last.end > gapThreshold,
           let interval = audibleInterval(start: last.end, end: audioDuration, gapThreshold: gapThreshold, nonSpeech: nonSpeech) {
            combined.append(AlignedLine(text: "♪", start: interval.start, end: interval.end))
        }

        return combined
    }

    // Returns the audible (non-silent) sub-interval within [start, end), or nil if the
    // surviving stretch is shorter than gapThreshold. The leading and trailing silence
    // is trimmed so the ♪ marker doesn't extend over quiet edges; small silent dips in
    // the middle are kept inside the marker (they are part of the same music run).
    static func audibleInterval(start: Double, end: Double, gapThreshold: Double, nonSpeech: NonSpeechDetector) -> (start: Double, end: Double)? {
        guard end > start else { return nil }

        // Trim leading silence: bump start forward past any silent interval that starts
        // at or before `start`.
        var trimmedStart = start
        for i in 0..<nonSpeech.silentStarts.count {
            if nonSpeech.silentStarts[i] <= trimmedStart && nonSpeech.silentEnds[i] > trimmedStart {
                trimmedStart = min(end, nonSpeech.silentEnds[i])
            }
        }
        // Trim trailing silence: pull end backward before any silent interval that ends
        // at or after `end`.
        var trimmedEnd = end
        for i in 0..<nonSpeech.silentStarts.count {
            if nonSpeech.silentStarts[i] < trimmedEnd && nonSpeech.silentEnds[i] >= trimmedEnd {
                trimmedEnd = max(trimmedStart, nonSpeech.silentStarts[i])
            }
        }
        let duration = trimmedEnd - trimmedStart
        guard duration >= gapThreshold else { return nil }

        // Reject the marker entirely when the gap is dominated by silence (more than half
        // silent after the trim) — that means there's no real music run to label.
        let silentInside = silentOverlap(silentStarts: nonSpeech.silentStarts, silentEnds: nonSpeech.silentEnds, start: trimmedStart, end: trimmedEnd)
        guard duration - silentInside >= gapThreshold else { return nil }
        return (trimmedStart, trimmedEnd)
    }

    // Sums silent regions overlapping [start, end).
    static func silentOverlap(silentStarts: [Double], silentEnds: [Double], start: Double, end: Double) -> Double {
        var total: Double = 0
        for i in 0..<silentStarts.count {
            let s = max(start, silentStarts[i])
            let e = min(end, silentEnds[i])
            if e > s { total += e - s }
        }
        return total
    }
}
