import Foundation

// Resolves "which audio time-range corresponds to this breakdown line?" by text-matching
// SongLine.original against SubtitleCue.text. SongLine has no timing of its own — timing
// lives in the SRT — so the only join key is the line text. We walk both sequences with a
// cursor (cues run forward through the song) so a chorus repeating "サヨナラ" matches its
// successive occurrences instead of all snapping to the first cue.
//
// Matching is whitespace-normalized equality. SRT lyric files in practice contain the
// same characters as the breakdown's line.original (the LLM is fed the verbatim note
// text), so equality after whitespace strip is enough for the common case. Lines that
// don't match any cue simply don't get a playback range — the UI hides their play button.
enum SongLineCueMatcher {

    // Returns line.index → (startMs, endMs) for lines whose text matches a single cue.
    // Lines with no match are absent from the map (caller treats that as "no audio range").
    static func computeRanges(
        lines: [SongLine],
        cues: [SubtitleCue]
    ) -> [Int: (startMs: Int, endMs: Int)] {
        var result: [Int: (startMs: Int, endMs: Int)] = [:]
        var cursor = 0

        for line in lines {
            let normLine = normalize(line.original)
            guard normLine.isEmpty == false else { continue }

            var i = cursor
            while i < cues.count {
                let normCue = normalize(cues[i].text)
                if normCue.isEmpty == false && normCue == normLine {
                    result[line.index] = (startMs: cues[i].startMs, endMs: cues[i].endMs)
                    cursor = i + 1
                    break
                }
                i += 1
            }
        }

        return result
    }

    // Whitespace strip for line/cue comparison. Drops spaces, tabs, and newlines, joining
    // the remainder. Keeps every other Unicode scalar so kana and kanji compare verbatim.
    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined()
    }
}
