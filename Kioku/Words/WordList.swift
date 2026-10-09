import Foundation

// Represents a user-created word list used to group saved vocabulary in the Words tab.
struct WordList: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
}

extension WordList {
    // Counts saved members of a list — words + kanji. Both record types share the same
    // WordList ids (see SavedKanji.wordListIDs), so a kanji-only list registers a non-zero
    // count instead of the misleading 0 counting only SavedWord entries would give.
    @MainActor
    static func memberCount(for listID: UUID, wordsStore: WordsStore, savedKanjiStore: SavedKanjiStore) -> Int {
        let words = wordsStore.words.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        let kanji = savedKanjiStore.kanji.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        return words + kanji
    }
}

// Shared shape of SavedWord and SavedKanji's note/list provenance, so the Words tab's note/list
// filter (WordsView+Actions's visibleWords / visibleSavedKanji) can filter either with one
// implementation instead of two copies of the same predicate.
protocol NoteAndListAttributed {
    var sourceNoteIDs: [UUID] { get }
    var wordListIDs: [UUID] { get }
}

// True when `item` matches an active note/list filter: it belongs to any of `noteIDs` (when
// non-empty) AND any of `listIDs` (when non-empty). An empty filter side always matches, so
// passing both empty matches everything.
func matchesNoteAndListFilter<T: NoteAndListAttributed>(_ item: T, noteIDs: Set<UUID>, listIDs: Set<UUID>) -> Bool {
    let matchesNote = noteIDs.isEmpty || noteIDs.contains { item.sourceNoteIDs.contains($0) }
    let matchesList = listIDs.isEmpty || listIDs.contains { item.wordListIDs.contains($0) }
    return matchesNote && matchesList
}
