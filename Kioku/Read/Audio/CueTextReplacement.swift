import Foundation

// Rewrites part of a cue's text while keeping its word timings pointed at the right characters —
// used when the note's text is edited in place (English → katakana) and the saved alignment should
// follow without a re-align. The audio didn't change, so no time moves: checkpoints before the edit
// stay put, the ones inside it merge into one covering the new text (at the earliest of their
// times), and the ones after it shift by the change in length.
nonisolated enum CueTextReplacement {
    // `cue` with the UTF-16 `range` of its text replaced by `replacement`; nil if the range doesn't
    // fit the cue's text.
    static func replacing(_ range: NSRange, with replacement: String, in cue: SubtitleCue) -> SubtitleCue? {
        let text = cue.text as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        let newLength = (replacement as NSString).length
        let delta = newLength - range.length
        var updated = cue
        updated.text = text.replacingCharacters(in: range, with: replacement)

        var kept: [CueCharTiming] = []
        var mergedTime: Int?
        for cp in cue.checkpoints {
            let end = cp.charOffsetInCue + cp.charLength
            if end <= range.location {
                kept.append(cp)
            } else if cp.charOffsetInCue >= NSMaxRange(range) {
                kept.append(CueCharTiming(timeMs: cp.timeMs, charOffsetInCue: cp.charOffsetInCue + delta, charLength: cp.charLength))
            } else {
                mergedTime = min(mergedTime ?? cp.timeMs, cp.timeMs)
            }
        }
        if let mergedTime, newLength > 0 {
            kept.append(CueCharTiming(timeMs: mergedTime, charOffsetInCue: range.location, charLength: newLength))
        }
        updated.checkpoints = kept.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
        return updated
    }
}
