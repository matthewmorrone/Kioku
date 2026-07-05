import Foundation

// Structural alignment check: which cues can NEVER become the active/highlighted line during
// playback. Mirrors AudioPlaybackController.resolveActiveCue's "current" rule — a cue is the active
// line only when it is the FIRST cue (in array order, which is what resolveActiveCue scans) whose
// half-open [startMs, endMs) contains the playhead. A cue therefore never wins that test when either:
//   • its interval is empty or inverted (startMs >= endMs) — no instant can fall inside it; or
//   • it is fully shadowed — every instant it covers is already claimed by an earlier-indexed cue.
// Note: resolveActiveCue's next/previous fallback can still make such a cue *flash* transiently, so
// "never the contains-playhead winner" is not identical to "never visibly lights up" — this reports
// the former, which is the actionable timing defect: it catches zero-duration lines and lines whose
// timing lands them fully behind another (e.g. a line placed on the wrong side of an interlude).
nonisolated enum CueReachabilityDiagnostic {
    // Why a cue can never be the contains-playhead winner.
    enum Reason: Equatable {
        case emptyInterval   // startMs >= endMs — no instant falls inside
        case shadowed        // every instant it covers is claimed by an earlier-indexed cue
    }

    // One un-highlightable cue. `arrayIndex` is its position in the scanned array (what the winner
    // rule keys on); `cueIndex` is the cue's own SRT number, for display.
    struct Finding: Equatable {
        let arrayIndex: Int
        let cueIndex: Int
        let reason: Reason
        let text: String
    }

    // Returns a finding for every cue that can never be the contains-playhead winner, in array order.
    static func unreachableCues(_ cues: [SubtitleCue]) -> [Finding] {
        var findings: [Finding] = []
        for i in cues.indices {
            let cue = cues[i]
            if cue.startMs >= cue.endMs {
                findings.append(Finding(arrayIndex: i, cueIndex: cue.index, reason: .emptyInterval, text: cue.text))
                continue
            }
            // Only earlier-indexed cues can shadow this one, matching firstIndex's scan order.
            let earlier = cues[0..<i]
                .map { (start: $0.startMs, end: $0.endMs) }
                .filter { $0.start < $0.end }
            if isFullyCovered(start: cue.startMs, end: cue.endMs, by: earlier) {
                findings.append(Finding(arrayIndex: i, cueIndex: cue.index, reason: .shadowed, text: cue.text))
            }
        }
        return findings
    }

    // True when [start, end) is entirely covered by the union of `intervals`. Sweeps the overlapping
    // intervals sorted by start, advancing a running coverage frontier; a gap before the frontier
    // reaches `end` means the target has an uncovered instant and is therefore reachable.
    private static func isFullyCovered(start: Int, end: Int, by intervals: [(start: Int, end: Int)]) -> Bool {
        let relevant = intervals
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
        var frontier = start
        for interval in relevant {
            if interval.start > frontier { return false }
            frontier = max(frontier, interval.end)
            if frontier >= end { return true }
        }
        return frontier >= end
    }
}
