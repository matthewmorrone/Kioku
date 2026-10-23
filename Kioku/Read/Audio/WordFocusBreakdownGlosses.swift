import Foundation

// The song breakdown's in-context meanings, placed in the note, for the word-focus view — the same
// source the lyrics card's bubbles prefer over the dictionary.
enum WordFocusBreakdownGlosses {
    // Each breakdown word found in the note (searched in order within its line, as the bubbles do)
    // with its short meaning; words whose definition is too long or qualified for a bubble are left out.
    static func glosses(lines: [SongLine], noteText: String) -> [(range: NSRange, gloss: String)] {
        let lineRanges = SongBreakdownLineLocator.noteRanges(for: lines, in: noteText)
        let note = noteText as NSString
        var result: [(range: NSRange, gloss: String)] = []
        for line in lines {
            guard let lineRange = lineRanges[line.index] else { continue }
            var cursor = lineRange.location
            for word in line.words {
                let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false, cursor < NSMaxRange(lineRange) else { continue }
                let found = note.range(of: surface, options: [], range: NSRange(location: cursor, length: NSMaxRange(lineRange) - cursor))
                guard found.location != NSNotFound else { continue }
                cursor = NSMaxRange(found)
                if let gloss = LyricsView.shortGloss(word.definition) { result.append((found, gloss)) }
            }
        }
        return result
    }
}
