import Foundation

// What the notes list is ordered by. `manual` is the user's own drag-to-reorder order — the
// order NotesStore persists in `_index.json` — and is the only field where reordering is
// allowed; every other field is a derived view over the same stored array, so switching back
// to `manual` restores the hand-arranged order untouched.
enum NotesSortField: String, CaseIterable, Identifiable {
    case manual
    case title
    case dateModified
    case dateCreated
    case length
    case wordsToLearn
    case difficulty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .title: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .length: "Length"
        case .wordsToLearn: "Words Left to Learn"
        case .difficulty: "Difficulty"
        }
    }

    // Direction the field reads most naturally in when first picked: alphabetical for names,
    // newest/longest/hardest first for everything else.
    var defaultAscending: Bool {
        self == .title
    }

    // Labels for the two directions, phrased per field so the menu never says a bare
    // "Ascending" the user has to translate into "oldest first".
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .manual: return ascending ? "Ascending" : "Descending"
        case .title: return ascending ? "A to Z" : "Z to A"
        case .dateModified: return ascending ? "Oldest First" : "Newest First"
        case .dateCreated: return ascending ? "Oldest First" : "Newest First"
        case .length: return ascending ? "Shortest First" : "Longest First"
        case .wordsToLearn: return ascending ? "Fewest First" : "Most First"
        case .difficulty: return ascending ? "Easiest First" : "Hardest First"
        }
    }
}

// The two learning-derived numbers a note can be sorted by. Supplied by the view from the
// word/dictionary stores so the sorting itself stays pure and unit-testable.
struct NoteSortMetrics: Equatable {
    // Saved words attributed to this note that are not yet Learned or Mastered.
    var wordsToLearn: Int
    // Mean JLPT difficulty of the note's saved words, N5 = 1 … N1 = 5. nil when none of the
    // note's words carry a JLPT level (or the note has no saved words at all) — such notes
    // sort last in both directions rather than pretending to be the easiest.
    var difficulty: Double?

    init(wordsToLearn: Int = 0, difficulty: Double? = nil) {
        self.wordsToLearn = wordsToLearn
        self.difficulty = difficulty
    }
}

enum NotesSorting {

    // Orders notes by the chosen field. The sort is stable: ties keep the notes' existing
    // relative order (the user's manual order), so equal-length or same-day notes don't
    // shuffle between renders. `manual` returns the input untouched.
    static func sorted(
        _ notes: [Note],
        field: NotesSortField,
        ascending: Bool,
        metrics: (Note) -> NoteSortMetrics = { _ in NoteSortMetrics() }
    ) -> [Note] {
        guard field != .manual else { return notes }

        // Decorate with the original index so the comparison can fall back to it and stay stable
        // (Swift's `sort` is not guaranteed stable on its own).
        let decorated = notes.enumerated().map { (index: $0.offset, note: $0.element) }

        func compare(_ lhs: (index: Int, note: Note), _ rhs: (index: Int, note: Note)) -> Bool {
            switch field {
            case .manual:
                return lhs.index < rhs.index
            case .title:
                let l = sortableTitle(for: lhs.note)
                let r = sortableTitle(for: rhs.note)
                let result = l.localizedCaseInsensitiveCompare(r)
                if result != .orderedSame { return ascending ? result == .orderedAscending : result == .orderedDescending }
            case .dateModified:
                if lhs.note.modifiedAt != rhs.note.modifiedAt {
                    return ascending ? lhs.note.modifiedAt < rhs.note.modifiedAt : lhs.note.modifiedAt > rhs.note.modifiedAt
                }
            case .dateCreated:
                if lhs.note.createdAt != rhs.note.createdAt {
                    return ascending ? lhs.note.createdAt < rhs.note.createdAt : lhs.note.createdAt > rhs.note.createdAt
                }
            case .length:
                let l = length(of: lhs.note)
                let r = length(of: rhs.note)
                if l != r { return ascending ? l < r : l > r }
            case .wordsToLearn:
                let l = metrics(lhs.note).wordsToLearn
                let r = metrics(rhs.note).wordsToLearn
                if l != r { return ascending ? l < r : l > r }
            case .difficulty:
                let l = metrics(lhs.note).difficulty
                let r = metrics(rhs.note).difficulty
                switch (l, r) {
                case let (l?, r?) where l != r:
                    return ascending ? l < r : l > r
                // Unrated notes sink to the bottom whichever way the sort runs.
                case (nil, _?): return false
                case (_?, nil): return true
                default: break
                }
            }

            return lhs.index < rhs.index
        }

        return decorated.sorted(by: compare).map(\.note)
    }

    // Notes are titled by their first line when the title field is blank, matching how the row
    // renders; a note with neither sorts under "Untitled Note" rather than to the very front.
    static func sortableTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        let firstContentLine = note.content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstContentLine.isEmpty ? "Untitled Note" : firstContentLine
    }

    // Length is measured in characters of body text, ignoring surrounding whitespace, so
    // trailing newlines from an import don't make one note look longer than another.
    static func length(of note: Note) -> Int {
        note.content.trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}
