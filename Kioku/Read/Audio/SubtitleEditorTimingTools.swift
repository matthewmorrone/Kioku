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
