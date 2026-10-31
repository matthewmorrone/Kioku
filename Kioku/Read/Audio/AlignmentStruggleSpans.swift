import Foundation

// Finds the parts of a note the forced aligner struggled to hear in the audio, so the Read tab can
// squiggle them. A checkpoint's confidence (CueCharTiming.confidence) is how strongly the audio
// backed its letters; a low one means the lyric text there probably doesn't match what is sung.
enum AlignmentStruggleSpans {
    // Checkpoints scoring under this are flagged. Healthy sung text peaks well above it; a first
    // line the model barely hears sits near 0.05 (CTCAlignmentCore.heardLetterProbability). A starting
    // point to tune on real songs.
    static let threshold: Float = 0.25

    // What the aligner made of the flagged checkpoint(s) under `location`, for the squiggle popup while
    // debugging: confidence, the phonemes the lyric asked for, and the ones the model's best guess
    // per frame spelled there. One line per checkpoint; empty when nothing flagged covers the point.
    static func evidence(at location: Int, cues: [SubtitleCue], highlightRanges: [NSRange?], threshold: Float = threshold) -> [String] {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            guard index < highlightRanges.count, let cueRange = highlightRanges[index] else { continue }
            for checkpoint in cue.checkpoints {
                guard let confidence = checkpoint.confidence, confidence < threshold else { continue }
                let start = cueRange.location + checkpoint.charOffsetInCue
                let end = min(start + checkpoint.charLength, NSMaxRange(cueRange))
                guard location >= start, location < end else { continue }
                let text = (cue.text as NSString).substring(with: NSRange(location: checkpoint.charOffsetInCue, length: min(checkpoint.charLength, (cue.text as NSString).length - checkpoint.charOffsetInCue)))
                let header = "\(text)  conf \(String(format: "%.2f", confidence))"
                guard let expected = checkpoint.expected, let heard = checkpoint.heard else {
                    lines.append("\(header)\n(no evidence saved: re-align this song)")
                    continue
                }
                lines.append("\(header)\nexpected: \(expected)\nheard: \(heard.isEmpty ? "(nothing)" : heard)")
            }
        }
        return lines
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
