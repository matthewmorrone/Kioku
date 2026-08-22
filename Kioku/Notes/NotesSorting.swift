import Foundation

// How the Notes tab orders its list. `manual` preserves the user's drag-reordered sequence (the
// order NotesStore persists in _index.json) and is the only field that allows reordering; every
// other field derives its order from note data, so drag-to-move is disabled while one is active.
enum NotesSortField: String, CaseIterable, Identifiable {
    case manual
    case title
    case modified
    case created
    case length
    case difficulty
    case wordsToLearn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual Order"
        case .title: "Name"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .length: "Length"
        case .difficulty: "Difficulty"
        case .wordsToLearn: "Words Left to Learn"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: "hand.draw"
        case .title: "textformat"
        case .modified: "clock.arrow.circlepath"
        case .created: "calendar"
        case .length: "textformat.size"
        case .difficulty: "chart.bar"
        case .wordsToLearn: "graduationcap"
        }
    }

    // Whether picking this field should start ascending. Names read best A→Z and length/difficulty
    // easiest-first, while dates and "how much is left" are most useful newest/most-first — the
    // same defaults Files and Photos use for their equivalents.
    var defaultsToAscending: Bool {
        switch self {
        case .manual, .title, .length, .difficulty: true
        case .modified, .created, .wordsToLearn: false
        }
    }

    // Direction labels shown next to the order toggle, phrased per field so "Ascending" never has
    // to stand in for "oldest first" or "easiest first".
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .manual: ascending ? "List Order" : "Reversed"
        case .title: ascending ? "A to Z" : "Z to A"
        case .modified, .created: ascending ? "Oldest First" : "Newest First"
        case .length: ascending ? "Shortest First" : "Longest First"
        case .difficulty: ascending ? "Easiest First" : "Hardest First"
        case .wordsToLearn: ascending ? "Fewest First" : "Most First"
        }
    }
}

// The per-note numbers a sort field needs that can't be read off `Note` itself. Supplied by the
// view from the live stores (words left to learn) so the sorter stays a pure function over values
// and can be unit-tested without WordsStore or SwiftUI.
struct NoteSortMetrics {
    // Saved words attributed to the note that aren't Learned/Mastered yet.
    var wordsToLearn: (Note) -> Int = { _ in 0 }

    // How demanding the note's text is to read, 0…1. Kanji density (kanji characters as a share of
    // all non-whitespace characters) is the whole heuristic: it needs no dictionary lookup, works
    // on a note that has no saved words at all, and tracks the thing that actually makes Japanese
    // prose hard to decode for a learner. Ties break on length, so two all-kana notes still order
    // sensibly.
    var difficulty: (Note) -> Double = { NoteTextMetrics.kanjiDensity(of: $0.content) }
}

// Pure text measurements over a note's content.
enum NoteTextMetrics {
    // Character count of the trimmed content — what the Length sort compares.
    static func length(of content: String) -> Int {
        content.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    // Share of non-whitespace characters that are kanji (CJK Unified Ideographs, including the
    // Extension A block). 0 for text with no visible characters.
    static func kanjiDensity(of content: String) -> Double {
        var visible = 0
        var kanji = 0
        for scalar in content.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            visible += 1
            if isKanji(scalar) { kanji += 1 }
        }
        return visible == 0 ? 0 : Double(kanji) / Double(visible)
    }

    private static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }
}

// Applies a NotesSortField to a notes array. Every comparison falls back to the incoming order
// (the manual/persisted sequence) on a tie, so the list never reshuffles between renders for
// notes the active field can't tell apart.
enum NotesSorter {

    static func sorted(
        _ notes: [Note],
        field: NotesSortField,
        ascending: Bool,
        metrics: NoteSortMetrics = NoteSortMetrics()
    ) -> [Note] {
        guard field != .manual else {
            return ascending ? notes : notes.reversed()
        }

        // Index by position so ties resolve to the original ordering rather than to whatever
        // `sorted(by:)` happens to produce — Swift's sort is not stable.
        let indexed = notes.enumerated().map { (offset: $0.offset, note: $0.element) }
        let ordered = indexed.sorted { lhs, rhs in
            switch compare(lhs.note, rhs.note, field: field, metrics: metrics) {
            case .orderedAscending: return ascending
            case .orderedDescending: return ascending == false
            case .orderedSame: return lhs.offset < rhs.offset
            }
        }
        return ordered.map(\.note)
    }

    // Compares two notes on one field, ascending. Returns .orderedSame when the field can't
    // separate them so the caller can apply its stable tie-break.
    private static func compare(
        _ lhs: Note,
        _ rhs: Note,
        field: NotesSortField,
        metrics: NoteSortMetrics
    ) -> ComparisonResult {
        switch field {
        case .manual:
            return .orderedSame
        case .title:
            // Untitled notes sort to the end of an A→Z list rather than to the top, where a run of
            // blank rows would otherwise bury every named note below the fold.
            let l = sortableTitle(lhs), r = sortableTitle(rhs)
            if l.isEmpty != r.isEmpty { return l.isEmpty ? .orderedDescending : .orderedAscending }
            // localizedStandardCompare gives case-insensitive, numeric-aware ("Lesson 2" before
            // "Lesson 10") ordering, matching how Files sorts names.
            let result = l.localizedStandardCompare(r)
            return result == .orderedSame ? .orderedSame : result
        case .modified:
            return compare(lhs.modifiedAt, rhs.modifiedAt)
        case .created:
            return compare(lhs.createdAt, rhs.createdAt)
        case .length:
            return compare(NoteTextMetrics.length(of: lhs.content), NoteTextMetrics.length(of: rhs.content))
        case .difficulty:
            let result = compare(metrics.difficulty(lhs), metrics.difficulty(rhs))
            guard result == .orderedSame else { return result }
            // Equal density (two all-kana notes, two empty notes): the longer text is the harder read.
            return compare(NoteTextMetrics.length(of: lhs.content), NoteTextMetrics.length(of: rhs.content))
        case .wordsToLearn:
            return compare(metrics.wordsToLearn(lhs), metrics.wordsToLearn(rhs))
        }
    }

    // The note's title for sorting purposes: trimmed, with a content fallback so a note that was
    // never named still lands somewhere meaningful instead of in the untitled bucket.
    private static func sortableTitle(_ note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        return note.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
