import Foundation

// Turns each timed cue into furigana runs for the lyrics Live Activity, which runs in the widget
// extension and so can't use the app's CoreText ruby renderer. Pure: reads the note's existing
// furigana tables (UTF-16 location → reading / kanji-run length) and does no lexical work.
enum LyricsActivityRubyBuilder {
    // Builds runs for every cue, index-aligned with `cues`. A cue's range in the note comes from
    // `highlightRanges` when resolved, else from a verbatim search for the cue text — the same
    // rule LyricsView uses for its active card. Cues not found in the note get one plain run.
    static func runs(
        cues: [SubtitleCue],
        highlightRanges: [NSRange?],
        noteText: String,
        furiganaBySegmentLocation: [Int: String],
        furiganaLengthBySegmentLocation: [Int: Int]
    ) -> [[LyricsActivityRubyRun]] {
        let note = noteText as NSString
        return cues.indices.map { index in
            let cueText = cues[index].text
            let resolved: NSRange? = {
                if index < highlightRanges.count, let range = highlightRanges[index] { return range }
                guard cueText.isEmpty == false else { return nil }
                let probe = note.range(of: cueText)
                return probe.location == NSNotFound ? nil : probe
            }()
            guard let range = resolved, NSMaxRange(range) <= note.length else {
                return plainRuns(firstLine(of: cueText))
            }
            return runs(
                in: range,
                of: note,
                furiganaBySegmentLocation: furiganaBySegmentLocation,
                furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation
            )
        }
    }

    // Splits the note slice `range` (clipped at its first newline, so a cue that bleeds into the
    // next line shows only its own) into alternating plain and ruby runs. Furigana entries are
    // kept only when their whole kanji run fits inside the slice.
    static func runs(
        in range: NSRange,
        of note: NSString,
        furiganaBySegmentLocation: [Int: String],
        furiganaLengthBySegmentLocation: [Int: Int]
    ) -> [LyricsActivityRubyRun] {
        let newline = note.rangeOfCharacter(from: .newlines, options: [], range: range)
        let start = range.location
        let end = newline.location == NSNotFound ? NSMaxRange(range) : newline.location
        let rubyStarts = furiganaBySegmentLocation.keys
            .filter { location in
                guard location >= start, let length = furiganaLengthBySegmentLocation[location] else { return false }
                return length > 0 && location + length <= end
            }
            .sorted()

        var result: [LyricsActivityRubyRun] = []
        var cursor = start
        for location in rubyStarts where location >= cursor {
            let length = furiganaLengthBySegmentLocation[location] ?? 0
            if location > cursor {
                result.append(LyricsActivityRubyRun(text: note.substring(with: NSRange(location: cursor, length: location - cursor)), ruby: nil))
            }
            result.append(LyricsActivityRubyRun(
                text: note.substring(with: NSRange(location: location, length: length)),
                ruby: furiganaBySegmentLocation[location]
            ))
            cursor = location + length
        }
        if cursor < end {
            result.append(LyricsActivityRubyRun(text: note.substring(with: NSRange(location: cursor, length: end - cursor)), ruby: nil))
        }
        return result
    }

    // One run with no furigana — the fallback when a cue has no place in the note text.
    static func plainRuns(_ text: String) -> [LyricsActivityRubyRun] {
        text.isEmpty ? [] : [LyricsActivityRubyRun(text: text, ruby: nil)]
    }

    // The first line of a possibly multi-line cue, trimmed — the line being sung.
    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
}
