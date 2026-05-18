import Foundation

// Maps TextGrid intervals onto cue character offsets.
// Strategy: pick the finest-resolution IntervalTier, walk its intervals in time order,
// prefix-match each non-empty label against the containing cue's text starting from a
// per-cue cursor. Mismatches are dropped silently (forced aligners are noisy).
nonisolated enum TextGridBinder {

    // Walks the highest-resolution IntervalTier and produces per-cue character checkpoints by
    // prefix-matching each non-empty label against the containing cue's text. Misaligned or
    // non-matching intervals are dropped silently so noisy forced-aligner output doesn't crash
    // the pipeline. The per-cue cursor never rewinds, preventing an out-of-order noisy interval
    // from re-matching an earlier character.
    static func bindCheckpoints(textGrid: TextGridFile, cues: [SubtitleCue]) -> CueCharTimings {
        let intervalTiers = textGrid.tiers.filter { $0.intervals.isEmpty == false }
        guard let tier = pickFinestTier(intervalTiers) else {
            KaraokeDebugLog.log("binder: no usable IntervalTier (tier count=\(textGrid.tiers.count))")
            return [:]
        }
        KaraokeDebugLog.log("binder: selected tier '\(tier.name)' (\(tier.intervals.count) intervals); \(cues.count) cues; firstCueText=\(cues.first?.text.prefix(30) ?? "")")

        let sortedCues = cues.sorted { $0.startMs < $1.startMs }

        var result: CueCharTimings = [:]
        var cursors: [Int: Int] = [:]
        var droppedNoCue = 0
        var droppedNoMatch = 0
        var droppedSilence = 0
        var sampleNoMatchExamples: [String] = []

        for interval in tier.intervals {
            if interval.text.isEmpty { droppedSilence += 1; continue }
            guard let cue = findContainingCue(timeMs: interval.startMs, in: sortedCues) else {
                droppedNoCue += 1
                continue
            }

            let cursor = cursors[cue.index] ?? 0
            guard let matchedLength = matchPrefix(label: interval.text, in: cue.text, fromUTF16Offset: cursor) else {
                droppedNoMatch += 1
                if sampleNoMatchExamples.count < 5 {
                    let cueSnippet = (cue.text as NSString).length > cursor
                        ? (cue.text as NSString).substring(with: NSRange(location: cursor, length: min(4, (cue.text as NSString).length - cursor)))
                        : "<EOL>"
                    sampleNoMatchExamples.append("'\(interval.text)' vs cue[\(cue.index)][\(cursor)+]='\(cueSnippet)'")
                }
                continue
            }

            let checkpoint = CueCharTiming(
                timeMs: interval.startMs,
                charOffsetInCue: cursor,
                charLength: matchedLength
            )
            result[cue.index, default: []].append(checkpoint)
            cursors[cue.index] = cursor + matchedLength
        }

        let totalCheckpoints = result.values.reduce(0) { $0 + $1.count }
        KaraokeDebugLog.log("binder: \(totalCheckpoints) checkpoints across \(result.count) cues | dropped: silence=\(droppedSilence) noCue=\(droppedNoCue) noMatch=\(droppedNoMatch)")
        for example in sampleNoMatchExamples {
            KaraokeDebugLog.log("binder noMatch sample: \(example)")
        }
        return result
    }

    // Picks the tier with the most intervals. Ties broken by name preference: phones > words > anything else.
    private static func pickFinestTier(_ tiers: [TextGridTier]) -> TextGridTier? {
        guard tiers.isEmpty == false else { return nil }
        let maxCount = tiers.map { $0.intervals.count }.max() ?? 0
        let candidates = tiers.filter { $0.intervals.count == maxCount }
        if candidates.count == 1 { return candidates[0] }
        let preference: [String: Int] = ["phones": 0, "words": 1]
        return candidates.min { a, b in
            (preference[a.name] ?? 99) < (preference[b.name] ?? 99)
        }
    }

    // Returns the cue whose [startMs, endMs] contains t. Allows ±50 ms tolerance at boundaries.
    // When t falls in two cues' tolerance bands (interval starts exactly on a boundary), the LATER
    // cue wins — an interval beginning at a line transition belongs to the line that's just starting.
    private static func findContainingCue(timeMs t: Int, in sorted: [SubtitleCue]) -> SubtitleCue? {
        let tolerance = 50
        var best: SubtitleCue? = nil
        for cue in sorted {
            if t + tolerance >= cue.startMs && t <= cue.endMs + tolerance {
                best = cue
            } else if cue.startMs > t + tolerance {
                break
            }
        }
        return best
    }

    // Tries to match `label` as a prefix of `text[cursor...]` measured in UTF-16 code units.
    private static func matchPrefix(label: String, in text: String, fromUTF16Offset cursor: Int) -> Int? {
        let nsText = text as NSString
        let labelLength = (label as NSString).length
        let textLength = nsText.length
        guard cursor + labelLength <= textLength else { return nil }
        let slice = nsText.substring(with: NSRange(location: cursor, length: labelLength))
        return slice == label ? labelLength : nil
    }
}
