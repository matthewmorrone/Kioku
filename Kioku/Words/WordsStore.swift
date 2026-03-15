import Combine
import Foundation
import SwiftUI

// Owns saved-word persistence for the Words tab. Replaces direct UserDefaults access in WordsView.
@MainActor
final class WordsStore: ObservableObject {
    @Published private(set) var words: [SavedWord] = []

    private let storageKey = "kioku.words.v1"

    init() {
        words = SavedWordStorageMigrator.loadSavedWords(storageKey: storageKey)
    }

    // Adds a word or merges it with an existing entry if already saved.
    func add(_ word: SavedWord) {
        var updated = words
        updated.append(word)
        persist(SavedWordStorageMigrator.normalizedEntries(updated))
    }

    // Removes a word by canonical entry id.
    func remove(id: Int64) {
        persist(words.filter { $0.canonicalEntryID != id })
    }

    // Toggles membership of a word in a word list; adds if absent, removes if present.
    func toggleListMembership(wordID: Int64, listID: UUID) {
        persist(words.map { word in
            guard word.canonicalEntryID == wordID else { return word }
            var updated = word
            if updated.wordListIDs.contains(listID) {
                updated.wordListIDs.removeAll { $0 == listID }
            } else {
                updated.wordListIDs.append(listID)
            }
            return updated
        })
    }

    // Strips a deleted list id from all saved words so no orphan memberships remain.
    func removeListMembership(listID: UUID) {
        persist(words.map { word in
            guard word.wordListIDs.contains(listID) else { return word }
            var updated = word
            updated.wordListIDs.removeAll { $0 == listID }
            return updated
        })
    }

    // Adds all specified word ids to a list. Words already in the list are unchanged.
    func addToList(wordIDs: Set<Int64>, listID: UUID) {
        persist(words.map { word in
            guard wordIDs.contains(word.canonicalEntryID), !word.wordListIDs.contains(listID) else { return word }
            var updated = word
            updated.wordListIDs.append(listID)
            return updated
        })
    }

    // Removes all specified word ids from a list. Words not in the list are unchanged.
    func removeFromList(wordIDs: Set<Int64>, listID: UUID) {
        persist(words.map { word in
            guard wordIDs.contains(word.canonicalEntryID), word.wordListIDs.contains(listID) else { return word }
            var updated = word
            updated.wordListIDs.removeAll { $0 == listID }
            return updated
        })
    }

    // Reorders words in response to a drag-and-drop move gesture from the list.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        var updated = words
        updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist(updated)
    }

    // Reloads the published words array from persistent storage. Called by external writers (e.g. SegmentListView) to keep the store in sync after a direct persist.
    func reload() {
        words = SavedWordStorageMigrator.loadSavedWords(storageKey: storageKey)
    }

    // Writes normalized entries to storage and refreshes the published array.
    private func persist(_ entries: [SavedWord]) {
        SavedWordStorageMigrator.persist(entries: entries, storageKey: storageKey)
        words = SavedWordStorageMigrator.loadSavedWords(storageKey: storageKey)
    }
}
