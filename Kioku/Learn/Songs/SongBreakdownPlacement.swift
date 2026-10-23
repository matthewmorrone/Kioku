import Foundation

// A song breakdown laid over the note it was generated from: which part of the note each line
// and each of its words is. The lyrics card's translation line and word bubbles and the
// word-by-word view all read the breakdown through this one join, so they agree on where a
// line or word is; SongBreakdownStore builds it once per breakdown and note text.
//
// Lines are placed by SongBreakdownLineLocator. A line's words are found in order inside its
// range with a forward-only cursor, so a word repeated in the line resolves to its own
// occurrence; a word the model spelled differently from the note is left out.
struct SongBreakdownPlacement {
    // The lines found in the note, in breakdown order.
    let lines: [SongBreakdownPlacedLine]
    // Each line's gist by its normalized text (SongLineCueMatcher.normalize), placed or not, for
    // cues the alignment didn't place in the note. The first line with a text keeps it.
    let gistsByNormalizedText: [String: String]

    // Places `breakdownLines` on `noteText`.
    init(breakdownLines: [SongLine], noteText: String) {
        let note = noteText as NSString
        let linesByIndex = Dictionary(breakdownLines.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let lineRanges = SongBreakdownLineLocator.noteRanges(for: breakdownLines, in: noteText)
        var placed: [SongBreakdownPlacedLine] = []
        var byText: [String: String] = [:]
        for line in breakdownLines {
            let gist = SongListenScript.effectiveGist(for: line, linesByIndex: linesByIndex)
            if let gist {
                let key = SongLineCueMatcher.normalize(line.original)
                if key.isEmpty == false, byText[key] == nil { byText[key] = gist }
            }
            // A repeated line number keeps its first occurrence, as the locator does.
            guard let range = lineRanges[line.index], placed.contains(where: { $0.line.index == line.index }) == false else { continue }
            placed.append(SongBreakdownPlacedLine(
                line: line,
                range: range,
                gist: gist,
                words: Self.placeWords(line.words, in: range, of: note)
            ))
        }
        lines = placed
        gistsByNormalizedText = byText
    }

    // Finds each word in `lineRange`, in order, each search starting after the previous find.
    private static func placeWords(_ words: [SongWord], in lineRange: NSRange, of note: NSString) -> [SongBreakdownPlacedWord] {
        var cursor = lineRange.location
        var placed: [SongBreakdownPlacedWord] = []
        for word in words {
            let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard surface.isEmpty == false, cursor < NSMaxRange(lineRange) else { continue }
            let found = note.range(of: surface, options: [], range: NSRange(location: cursor, length: NSMaxRange(lineRange) - cursor))
            guard found.location != NSNotFound else { continue }
            cursor = NSMaxRange(found)
            placed.append(SongBreakdownPlacedWord(word: word, range: found))
        }
        return placed
    }

    // The placed line holding a note location, for joining a lyric cue to its line by position.
    func line(containing location: Int) -> SongBreakdownPlacedLine? {
        lines.first { NSLocationInRange(location, $0.range) }
    }

    // The first placed line overlapping a note range, for joining a cue span to its line.
    func line(overlapping range: NSRange) -> SongBreakdownPlacedLine? {
        lines.first { NSIntersectionRange($0.range, range).length > 0 }
    }

    // The gist for a lyric line: the placed line at `location`'s, else the gist of a line whose
    // text is `text`, else nil.
    func gist(atNoteLocation location: Int?, text: String) -> String? {
        if let location, let gist = line(containing: location)?.gist { return gist }
        return gistsByNormalizedText[SongLineCueMatcher.normalize(text)]
    }

    // The placed words overlapping a note range, in note order, for a word's in-context meaning.
    func words(overlapping range: NSRange) -> [SongBreakdownPlacedWord] {
        lines.filter { NSIntersectionRange($0.range, range).length > 0 }
            .flatMap { $0.words.filter { NSIntersectionRange($0.range, range).length > 0 } }
    }
}
