import Combine
import Foundation
import SwiftUI

// Owns saved-word persistence for the Words tab. Replaces direct UserDefaults access in WordsView.
@MainActor
final class WordsStore: ObservableObject {
    @Published private(set) var words: [SavedWord] = []

    private let storageKey = "kioku.words.v1"

    init() {
        let key = storageKey
        words = StartupTimer.measure("WordsStore.init") {
            SavedWordStorage.loadSavedWords(storageKey: key)
        }
    }

    // Adds a word or merges it with an existing entry if already saved.
    func add(_ word: SavedWord) {
        var updated = words
        updated.append(word)
        persist(updated)
    }

    // Adds many words in one persist cycle. Bulk callers (CSV import, batch saves) must use this
    // instead of looping over add(_:) so they trigger one normalize + encode + UserDefaults write
    // instead of N — a per-item loop blocks the main thread for hundreds of milliseconds on large
    // imports because each iteration round-trips through JSON and UserDefaults.
    func add(_ newWords: [SavedWord]) {
        guard !newWords.isEmpty else { return }
        persist(words + newWords)
    }

    // Removes a word by canonical entry id.
    func remove(id: Int64) {
        persist(words.filter { $0.canonicalEntryID != id })
    }

    // Removes many words in one persist cycle. Bulk callers (multi-select delete in WordsView)
    // must use this instead of looping over remove(id:) so the persist work is paid once, not N
    // times — the per-item loop is the source of the UI freeze when deleting many words.
    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        persist(words.filter { !ids.contains($0.canonicalEntryID) })
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

    // Updates the personal note on a saved word.
    func updatePersonalNote(id: Int64, note: String?) {
        persist(words.map { word in
            guard word.canonicalEntryID == id else { return word }
            var updated = word
            updated.personalNote = note
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
        words = SavedWordStorage.loadSavedWords(storageKey: storageKey)
    }

    // Replaces the saved-word store with one canonical snapshot.
    func replaceAll(with words: [SavedWord]) {
        persist(words)
    }

    // Normalizes once, writes the canonical snapshot to storage, and assigns it directly to the
    // published array. The previous implementation re-read and re-decoded the just-written data
    // from UserDefaults on every mutation, which doubled the per-call cost for no benefit — the
    // normalized array we just computed is the same data the round-trip would return.
    private func persist(_ entries: [SavedWord]) {
        let normalized = SavedWordStorage.normalizedEntries(entries)
        SavedWordStorage.writeNormalized(normalized, storageKey: storageKey)
        words = normalized
    }
}
