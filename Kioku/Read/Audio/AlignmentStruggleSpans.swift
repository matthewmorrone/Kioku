import Foundation

// Finds the parts of a note the forced aligner struggled to hear in the audio, so the Read tab can
// squiggle them. A checkpoint's confidence (CueCharTiming.confidence) is how strongly the audio
// backed its letters; a low one means the lyric text there probably doesn't match what is sung.
enum AlignmentStruggleSpans {
    // Checkpoints scoring under this are flagged. Healthy sung text peaks well above it; a first
    // line the model barely hears sits near 0.05 (CTCAlignmentCore.heardLetterProbability). A starting
    // point to tune on real songs.
    static let threshold: Float = 0.25

    // The flagged checkpoint under `location`, for the squiggle popup and the correction editor: its
    // note range and text, plus confidence, the phonemes the lyric asked for and the ones the model's
    // best guess per frame spelled there. Nil when no flagged checkpoint covers the point.
    static func target(at location: Int, cues: [SubtitleCue], highlightRanges: [NSRange?], threshold: Float = threshold) -> StruggleTarget? {
        for (index, cue) in cues.enumerated() {
            guard index < highlightRanges.count, let cueRange = highlightRanges[index] else { continue }
            let cueText = cue.text as NSString
            for checkpoint in cue.checkpoints {
                guard let confidence = checkpoint.confidence, confidence < threshold else { continue }
                let start = cueRange.location + checkpoint.charOffsetInCue
                let end = min(start + checkpoint.charLength, NSMaxRange(cueRange))
                guard location >= start, location < end, checkpoint.charOffsetInCue + (end - start) <= cueText.length else { continue }
                let text = cueText.substring(with: NSRange(location: checkpoint.charOffsetInCue, length: end - start))
                let header = "\(text)  conf \(String(format: "%.2f", confidence))"
                guard let expected = checkpoint.expected, let heard = checkpoint.heard else {
                    return StruggleTarget(range: NSRange(location: start, length: end - start), text: text,
                                          detail: "\(header)\n(no evidence saved: re-align this song)")
                }
                return StruggleTarget(range: NSRange(location: start, length: end - start), text: text,
                                      detail: "\(header)\nexpected: \(expected)\nheard: \(heard.isEmpty ? "(nothing)" : heard)")
            }
        }
        return nil
    }

    // Note ranges (UTF-16) of low-confidence checkpoints, in note order with touching ranges merged.
    // `highlightRanges[i]` is cue i's range in the note (nil when the cue wasn't found there); a
    // checkpoint's offset is relative to its cue's text, so it lands at the cue's start plus that
    // offset, clamped to the cue's range. Cues without confidences (older notes, SRT import) add none.
    static func ranges(cues: [SubtitleCue], highlightRanges: [NSRange?], threshold: Float = threshold) -> [NSRange] {
        var flagged: [NSRange] = []
        for (index, cue) in cues.enumerated() {
            guard index < highlightRanges.count, let cueRange = highlightRanges[index] else { continue }
            for checkpoint in cue.checkpoints {
                guard let confidence = checkpoint.confidence, confidence < threshold else { continue }
                let start = cueRange.location + checkpoint.charOffsetInCue
                let end = min(start + checkpoint.charLength, NSMaxRange(cueRange))
                guard start >= cueRange.location, end > start else { continue }
                flagged.append(NSRange(location: start, length: end - start))
            }
        }
        var merged: [NSRange] = []
        for range in flagged.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
