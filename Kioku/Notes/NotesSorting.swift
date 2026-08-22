import Foundation

// Pure ordering logic behind the Notes tab's sort menu: turns the stored note array plus a
// per-note metrics lookup into the array the list renders.
enum NotesSorting {

    // Difficulty weight for a single word's JLPT level: N5 (easiest) = 1 … N1 = 5, and words
    // with no JLPT level = 6, since those are typically beyond the JLPT vocabulary lists rather
    // than easier than N5.
    static func difficultyWeight(forJLPTLevel level: Int?) -> Double {
        guard let level else { return 6 }
        return Double(6 - min(max(level, 1), 5))
    }

    // Mean difficulty weight across a note's word levels, or nil when it has no words.
    static func difficulty(forJLPTLevels levels: [Int?]) -> Double? {
        guard levels.isEmpty == false else { return nil }
        return levels.reduce(0.0) { $0 + difficultyWeight(forJLPTLevel: $1) } / Double(levels.count)
    }

    // Orders `notes` for display. `manual` returns them untouched. Every other order is stable:
    // ties fall back to the note's position in the incoming (manual) array, so equal keys keep
    // the arrangement the user already knows and the list never reshuffles arbitrarily.
    static func sorted(
        _ notes: [Note],
        by order: NotesSortOrder,
        metrics: (Note) -> NoteSortMetrics = { _ in NoteSortMetrics() }
    ) -> [Note] {
        guard order != .manual else { return notes }

        let indexed = notes.enumerated().map { (position: $0.offset, note: $0.element, metrics: metrics($0.element)) }

        // Sorts on one comparable key in either direction, breaking ties on the note's stored
        // position so the ordering stays stable.
        func by<Key: Comparable>(_ key: (Note, NoteSortMetrics) -> Key, ascending: Bool) -> [Note] {
            indexed.sorted { lhs, rhs in
                let l = key(lhs.note, lhs.metrics)
                let r = key(rhs.note, rhs.metrics)
                if l != r { return ascending ? l < r : l > r }
                return lhs.position < rhs.position
            }.map(\.note)
        }

        switch order {
        case .manual:
            return notes
        case .titleAToZ, .titleZToA:
            // Sorts on the displayed title, so untitled notes compare as "Untitled Note" rather
            // than as an empty string that would clump them all at the A end.
            return by({ note, _ in sortTitle(for: note) }, ascending: order == .titleAToZ)
        case .recentlyModified:
            return by({ note, _ in note.modifiedAt }, ascending: false)
        case .leastRecentlyModified:
            return by({ note, _ in note.modifiedAt }, ascending: true)
        case .newestCreated:
            return by({ note, _ in note.createdAt }, ascending: false)
        case .oldestCreated:
            return by({ note, _ in note.createdAt }, ascending: true)
        case .longest:
            return by({ _, m in m.length }, ascending: false)
        case .shortest:
            return by({ _, m in m.length }, ascending: true)
        case .hardest, .easiest:
            // Notes without saved words have no difficulty to compare; they go last in both
            // directions, which a plain sort on an optional key can't express.
            let scored = indexed.filter { $0.metrics.difficulty != nil }
            let unscored = indexed.filter { $0.metrics.difficulty == nil }
            let ascending = order == .easiest
            let ordered = scored.sorted { lhs, rhs in
                let l = lhs.metrics.difficulty ?? 0
                let r = rhs.metrics.difficulty ?? 0
                if l != r { return ascending ? l < r : l > r }
                return lhs.position < rhs.position
            }
            return (ordered + unscored).map(\.note)
        case .mostWordsLeft:
            return by({ _, m in m.wordsLeftToLearn }, ascending: false)
        case .fewestWordsLeft:
            return by({ _, m in m.wordsLeftToLearn }, ascending: true)
        }
    }

    // Case- and diacritic-insensitive key for title sorting, with the same "Untitled Note"
    // fallback the rest of the Notes tab shows for a blank title.
    static func sortTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled Note" : trimmed
        return title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
