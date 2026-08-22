import Foundation

// Sort orders for the Notes tab list.
//
// `.manual` is the default and preserves the historical behavior: the notes array itself is
// the user's order (new notes at the top, drag-to-reorder persisted in NotesStore's
// `_index.json`). Every other case derives a sorted copy for display only — it never writes
// back to the store, and NotesView disables drag-reorder while one is active, since the
// dragged offsets would otherwise refer to the sorted array rather than the stored one.
enum NotesSortOrder: String, CaseIterable, Identifiable {
    case manual
    case titleAToZ
    case titleZToA
    case newestCreated
    case oldestCreated
    case recentlyModified
    case leastRecentlyModified
    case longest
    case shortest
    case mostWordsToLearn
    case fewestWordsToLearn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .titleAToZ: "Title A to Z"
        case .titleZToA: "Title Z to A"
        case .newestCreated: "Newest Created"
        case .oldestCreated: "Oldest Created"
        case .recentlyModified: "Recently Modified"
        case .leastRecentlyModified: "Least Recently Modified"
        case .longest: "Longest"
        case .shortest: "Shortest"
        case .mostWordsToLearn: "Most Words Left to Learn"
        case .fewestWordsToLearn: "Fewest Words Left to Learn"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: "hand.draw"
        case .titleAToZ, .titleZToA: "textformat"
        case .newestCreated, .oldestCreated: "calendar"
        case .recentlyModified, .leastRecentlyModified: "clock"
        case .longest, .shortest: "textformat.size"
        case .mostWordsToLearn, .fewestWordsToLearn: "graduationcap"
        }
    }

    // True for the orders that actually consult the learn counts, so callers can skip building
    // them (a full pass over the saved words) for every other sort.
    var usesWordsLeftToLearn: Bool {
        self == .mostWordsToLearn || self == .fewestWordsToLearn
    }

    // A note's sortable title. Mirrors NotesView.resolvedTitle so untitled notes sort where the
    // user sees them ("Untitled Note") instead of collapsing to the front as empty strings.
    static func sortTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }

    // Content length used by `.longest` / `.shortest`, in characters.
    static func length(of note: Note) -> Int { note.content.count }

    // Sorts notes for display.
    //
    // `wordsLeftToLearn` supplies the per-note count of saved words attributed to that note that
    // aren't marked learned yet; it's injected rather than read from WordsStore directly so this
    // stays a pure function (and testable without the store). It is only consulted by the two
    // learn-count cases.
    //
    // Every comparison falls back to the note's position in `notes` when the keys tie, so the
    // sort is stable and equal-key notes keep their manual order.
    static func sorted(
        _ notes: [Note],
        by order: NotesSortOrder,
        wordsLeftToLearn: (Note) -> Int = { _ in 0 }
    ) -> [Note] {
        guard order != .manual else { return notes }

        let positions = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.id, $0.offset) })
        // Falls back to the note's manual position when a comparison has no opinion, which is what
        // makes every sort below stable without relying on sorted(by:) being one.
        func stable(_ lhs: Note, _ rhs: Note, _ areInOrder: Bool?) -> Bool {
            areInOrder ?? ((positions[lhs.id] ?? 0) < (positions[rhs.id] ?? 0))
        }
        // Returns nil when the two keys are equal so the caller falls back to manual position.
        func compare<T: Comparable>(_ lhs: T, _ rhs: T, ascending: Bool) -> Bool? {
            lhs == rhs ? nil : (ascending ? lhs < rhs : lhs > rhs)
        }

        switch order {
        case .manual:
            return notes
        case .titleAToZ, .titleZToA:
            let ascending = order == .titleAToZ
            return notes.sorted { lhs, rhs in
                let l = sortTitle(for: lhs)
                let r = sortTitle(for: rhs)
                // Localized case-insensitive so Japanese titles and mixed casing order the way
                // the list renders them rather than by raw scalar value.
                let result = l.localizedStandardCompare(r)
                if result == .orderedSame { return stable(lhs, rhs, nil) }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .newestCreated:
            return notes.sorted { stable($0, $1, compare($0.createdAt, $1.createdAt, ascending: false)) }
        case .oldestCreated:
            return notes.sorted { stable($0, $1, compare($0.createdAt, $1.createdAt, ascending: true)) }
        case .recentlyModified:
            return notes.sorted { stable($0, $1, compare($0.modifiedAt, $1.modifiedAt, ascending: false)) }
        case .leastRecentlyModified:
            return notes.sorted { stable($0, $1, compare($0.modifiedAt, $1.modifiedAt, ascending: true)) }
        case .longest:
            return notes.sorted { stable($0, $1, compare(length(of: $0), length(of: $1), ascending: false)) }
        case .shortest:
            return notes.sorted { stable($0, $1, compare(length(of: $0), length(of: $1), ascending: true)) }
        case .mostWordsToLearn, .fewestWordsToLearn:
            let ascending = order == .fewestWordsToLearn
            let counts = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, wordsLeftToLearn($0)) })
            return notes.sorted {
                stable($0, $1, compare(counts[$0.id] ?? 0, counts[$1.id] ?? 0, ascending: ascending))
            }
        }
    }
}
