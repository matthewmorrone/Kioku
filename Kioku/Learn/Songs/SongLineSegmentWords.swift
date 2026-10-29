import Foundation

// Groups a breakdown line's words and segments into the rows of an expanded card's split line: each
// word with a gloss takes the segments it overlaps, and words sharing a segment share a row. Words are
// found in the line in order (a repeated word takes its next occurrence); a word whose surface isn't
// in the line, or that has no gloss, gets no row.
enum SongLineSegmentWords {
    // The rows in line order, each with its segments in order and its words in breakdown order.
    static func rows(
        words: [SongWord],
        in text: String,
        pieces: [SongLineSegmentPiece]
    ) -> [SongLineSegmentRow] {
        let pieceRanges = pieces.map { NSRange(location: $0.location, length: ($0.cache.sourceText as NSString).length) }
        var groups: [(locations: Set<Int>, words: [SongWord])] = []
        for (word, range) in zip(words, ranges(of: words, in: text)) where word.definition.isEmpty == false {
            guard let found = range else { continue }
            let covered = Set(pieceRanges.filter { NSIntersectionRange($0, found).length > 0 }.map(\.location))
            guard covered.isEmpty == false else { continue }
            // Folds in every row this word's segments already belong to.
            let overlapping = groups.indices.filter { groups[$0].locations.isDisjoint(with: covered) == false }
            var merged = (locations: covered, words: [SongWord]())
            for index in overlapping {
                merged.locations.formUnion(groups[index].locations)
                merged.words.append(contentsOf: groups[index].words)
            }
            merged.words.append(word)
            for index in overlapping.reversed() { groups.remove(at: index) }
            groups.append(merged)
        }
        return groups
            .map { SongLineSegmentRow(pieceLocations: $0.locations.sorted(), words: $0.words) }
            .sorted { ($0.pieceLocations.first ?? 0) < ($1.pieceLocations.first ?? 0) }
    }

    // Where each word sits in the line (UTF-16), found in order so a repeated word takes its next
    // occurrence; nil for a word whose surface isn't in the line.
    static func ranges(of words: [SongWord], in text: String) -> [NSRange?] {
        let nsText = text as NSString
        var cursor = 0
        return words.map { word in
            let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard surface.isEmpty == false else { return nil }
            var found = nsText.range(of: surface, range: NSRange(location: cursor, length: nsText.length - cursor))
            // Breakdowns don't always list words in sentence order; fall back to the first match.
            if found.location == NSNotFound {
                found = nsText.range(of: surface)
            } else {
                cursor = NSMaxRange(found)
            }
            return found.location == NSNotFound ? nil : found
        }
    }
}
