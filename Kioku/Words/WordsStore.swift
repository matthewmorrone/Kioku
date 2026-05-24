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

    // Replaces both selection arrays for one saved word in a single persist pass.
    // Callers (the WordDetailView picker) compute the post-toggle state including any
    // mutual-exclusion fold (whole sense vs. its glosses) before calling.
    func setSelection(id: Int64, senseIDs: [Int64], glosses: [GlossRef]) {
        persist(words.map { word in
            guard word.canonicalEntryID == id else { return word }
            var updated = word
            updated.selectedSenseIDs = senseIDs
            updated.selectedGlosses = glosses
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

    // Canonical save/unsave entry point. All UI surfaces (Words tab search, history rows,
    // browse-frequency sheet, segment-list star, in-text lookup-sheet star, nested-lookup
    // star) go through this method so the bookkeeping stays in one place — encountered-
    // surface tracking, per-note attribution, default sense-ID seeding, and card-removal
    // semantics can't drift between surfaces.
    //
    // Toggle semantics: for an existing card, flip membership of `encounteredSurface` in
    // the card's `encounteredSurfaces` set and of `sourceNoteID` in its `sourceNoteIDs`
    // attribution. The card is removed only when BOTH sets become empty — so a "save"
    // attributed to one note doesn't accidentally remove the card's attribution from
    // another note. For a brand-new card, the stored surface is lemma-normalized at
    // create time (callers pass the lemma form as `storedSurface` and the encountered
    // form — the user's clicked surface — as `encounteredSurface`), so star state on
    // the lemma row and the encountered row both light up correctly.
    //
    // Callers without segment context (Words tab, history, browse) pass nil for
    // `encounteredSurface` (defaulting to `storedSurface`) and nil for `sourceNoteID`,
    // which collapses to "toggle the card globally" — the card is removed when its
    // only encountered surface is the toggled one and no note attributions exist.
    func toggle(
        canonicalEntryID: Int64,
        storedSurface: String,
        encounteredSurface: String? = nil,
        sourceNoteID: UUID? = nil,
        defaultSenseIDs: [Int64] = []
    ) {
        let encountered = encounteredSurface ?? storedSurface
        var entries = words
        if let existingIndex = entries.firstIndex(where: { $0.canonicalEntryID == canonicalEntryID }) {
            let existingEntry = entries[existingIndex]
            var encounteredSet = existingEntry.encounteredSurfaces
            var noteIDs = Set(existingEntry.sourceNoteIDs)

            let surfaceWasInSet = encounteredSet.contains(encountered)
            let noteWasAttached = sourceNoteID.map { noteIDs.contains($0) } ?? false
            // "Saved here" = both the surface is in the set AND the note is attached
            // (when there's a note context). Without a note context, surface membership
            // alone determines it.
            let wasSavedHere: Bool = {
                guard sourceNoteID != nil else { return surfaceWasInSet }
                return surfaceWasInSet && noteWasAttached
            }()

            if wasSavedHere {
                encounteredSet.remove(encountered)
                if let sourceNoteID, encounteredSet.isEmpty {
                    // Last encountered surface gone for this card → drop this note's
                    // attribution. The card disappears entirely if no other note
                    // still has it on file.
                    noteIDs.remove(sourceNoteID)
                }
            } else {
                encounteredSet.insert(encountered)
                if let sourceNoteID {
                    noteIDs.insert(sourceNoteID)
                }
            }

            if encounteredSet.isEmpty && noteIDs.isEmpty {
                entries.remove(at: existingIndex)
            } else {
                let orderedNoteIDs = noteIDs.sorted { $0.uuidString < $1.uuidString }
                entries[existingIndex] = SavedWord(
                    canonicalEntryID: existingEntry.canonicalEntryID,
                    surface: existingEntry.surface,
                    sourceNoteIDs: orderedNoteIDs,
                    wordListIDs: existingEntry.wordListIDs,
                    personalNote: existingEntry.personalNote,
                    savedAt: existingEntry.savedAt,
                    selectedSenseIDs: existingEntry.selectedSenseIDs,
                    selectedGlosses: existingEntry.selectedGlosses,
                    encounteredSurfaces: encounteredSet
                )
            }
        } else {
            let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
            entries.append(
                SavedWord(
                    canonicalEntryID: canonicalEntryID,
                    surface: storedSurface,
                    sourceNoteIDs: noteIDs,
                    selectedSenseIDs: defaultSenseIDs,
                    encounteredSurfaces: [encountered]
                )
            )
        }

        replaceAll(with: entries)
    }

    // Normalizes once, writes the canonical snapshot to storage, then publishes the same array
    // to memory. The synchronous write closes the durability gap that an off-main write would
    // open if the app is force-quit before the queue drains; the previous read-back via
    // SavedWordStorage.loadSavedWords is gone, so this stays a single normalize + encode + write.
    private func persist(_ entries: [SavedWord]) {
        let normalized = SavedWordStorage.normalizedEntries(entries)
        SavedWordStorage.writeNormalized(normalized, storageKey: storageKey)
        words = normalized
    }
}
