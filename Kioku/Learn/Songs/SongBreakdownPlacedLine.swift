import Foundation

// A breakdown line found in its note: the line, its UTF-16 range in the note text, its gist
// (its own, else the referenced line's for a repeat) and its own words, each found in the note.
// Built by SongBreakdownPlacement; pure data.
nonisolated struct SongBreakdownPlacedLine {
    let line: SongLine
    let range: NSRange
    let gist: String?
    let words: [SongBreakdownPlacedWord]
}

// One of a placed line's words, with its UTF-16 range in the note text.
nonisolated struct SongBreakdownPlacedWord {
    let word: SongWord
    let range: NSRange
}
