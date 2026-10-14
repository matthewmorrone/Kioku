import Foundation

// Places each breakdown line on the note it was generated from: line.index → the UTF-16 range
// of that line's text within the note. Every surface that joins a breakdown line to the note —
// the breakdown's own furigana (sliced from the Read tab's readings) and the lyrics popup's
// gist lookup (by the active cue's note position) — goes through this one mapping, so they
// agree on which part of the note a line is.
//
// Walks lines in order with a forward-only cursor, so a repeated chorus line resolves to its
// own occurrence rather than always the first. A line the model shortened on the user's
// instruction (a dropped "(セーラースマイル)") still lands, since it's found as a substring of the
// note line; a line whose text the model changed doesn't appear in the note and is omitted.
enum SongBreakdownLineLocator {

    // Returns line.index → the line's range in `noteText`. When the model repeats a line
    // number, the first occurrence keeps it.
    static func noteRanges(for lines: [SongLine], in noteText: String) -> [Int: NSRange] {
        let note = noteText as NSString
        var ranges: [Int: NSRange] = [:]
        var cursor = 0
        for line in lines {
            let text = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false, ranges[line.index] == nil, cursor < note.length else { continue }
            let found = note.range(of: text, range: NSRange(location: cursor, length: note.length - cursor))
            guard found.location != NSNotFound else { continue }
            ranges[line.index] = found
            cursor = found.location + found.length
        }
        return ranges
    }
}
