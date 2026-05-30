import Combine
import Foundation
import SwiftUI

// Box that lets the persist queue ship a UserDefaults across the Sendable boundary even
// though Foundation hasn't yet annotated UserDefaults as Sendable. Apple documents
// UserDefaults as thread-safe; this box is the one place we encode that promise.
nonisolated private final class UncheckedSendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(value: UserDefaults) { self.value = value }
}

// Owns saved-word persistence for the Words tab. Replaces direct UserDefaults access in WordsView.
@MainActor
final class WordsStore: ObservableObject {
    @Published private(set) var words: [SavedWord] = []

    // nonisolated(unsafe) on userDefaults because UserDefaults isn't formally Sendable
    // in the SDK but Apple documents it as thread-safe — the persist() background
    // dispatch needs to capture it without the @MainActor isolation of WordsStore
    // making sending it a race per Swift 6 strict checking.
    nonisolated(unsafe) private let userDefaults: UserDefaults
    nonisolated private let storageKey: String

    // Both the UserDefaults instance and the storage key are parameterized so tests can scope
    // each case to a per-suite UserDefaults without leaking into .standard. Production callers
    // get the defaults and keep using the v1 key.
    init(userDefaults: UserDefaults = .standard, storageKey: String = "kioku.words.v1") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        let key = storageKey
        let defaults = userDefaults
        words = StartupTimer.measure("WordsStore.init") {
            SavedWordStorage.loadSavedWords(storageKey: key, userDefaults: defaults)
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

    // Re-points a saved card to a different dictionary entry — the fix for a card that
    // resolved to the wrong lemma (e.g. した saved as 下 when the user meant the verb する).
    // List membership, personal note, source notes, and save date carry over; the old surface
    // folds into encounteredSurfaces; sense/gloss selections reset because they reference the
    // OLD entry's senses. If the target entry is already saved, the two cards merge onto it
    // (union of lists/notes/surfaces) so identity (keyed by canonicalEntryID) stays unique.
    func repoint(fromEntryID oldID: Int64, toEntryID newID: Int64, lemma: String) {
        guard oldID != newID,
              let old = words.first(where: { $0.canonicalEntryID == oldID }) else { return }

        let existing = words.first(where: { $0.canonicalEntryID == newID })

        var encountered = old.encounteredSurfaces
        encountered.insert(old.surface)
        if let existing { encountered.formUnion(existing.encounteredSurfaces) }

        let mergedLists = Array(Set(old.wordListIDs).union(existing?.wordListIDs ?? []))
        let mergedNotes = Array(Set(old.sourceNoteIDs).union(existing?.sourceNoteIDs ?? []))

        let repointed = SavedWord(
            canonicalEntryID: newID,
            surface: lemma,
            sourceNoteIDs: mergedNotes,
            wordListIDs: mergedLists,
            personalNote: old.personalNote ?? existing?.personalNote,
            savedAt: old.savedAt,
            selectedSenseIDs: [],
            selectedGlosses: [],
            encounteredSurfaces: encountered
        )

        // Keep the card roughly where the old one sat; drop both old and any target collision first.
        let insertIndex = words.firstIndex(where: { $0.canonicalEntryID == oldID }) ?? words.count
        var updated = words.filter { $0.canonicalEntryID != oldID && $0.canonicalEntryID != newID }
        updated.insert(repointed, at: min(insertIndex, updated.count))
        persist(updated)
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
        words = SavedWordStorage.loadSavedWords(storageKey: storageKey, userDefaults: userDefaults)
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

    // Normalizes on main (cheap, hashmap merge), publishes the new array immediately so
    // SwiftUI repaints on the same runloop tick, then dispatches the JSON encode +
    // UserDefaults write off-main on a SERIAL queue. The serial queue preserves write
    // ordering (so a rapid sequence of toggles can't land out-of-order on disk) and
    // avoids the snapshot-replace race: we never read back from the background path
    // into @Published `words`, so a newer main-thread mutation can't be clobbered by
    // a stale background write completing later.
    //
    // Durability tradeoff: a hard kill in the millisecond window between publish and
    // disk write loses the latest toggle. Acceptable for this use case — the user can
    // re-tap, and the alternative (sync write on main) was the bottleneck on the
    // star-tap path.
    private func persist(_ entries: [SavedWord]) {
        let normalized = SavedWordStorage.normalizedEntries(entries)
        words = normalized
        let storageKey = self.storageKey
        // UserDefaults isn't formally Sendable in the SDK but Apple documents it as
        // thread-safe — wrap in an @unchecked Sendable box so the persistQueue capture
        // satisfies Swift 6 strict-concurrency without spraying nonisolated(unsafe)
        // through every call-site.
        let userDefaults = UncheckedSendableUserDefaults(value: self.userDefaults)
        WordsStore.persistQueue.async {
            SavedWordStorage.writeNormalized(normalized, storageKey: storageKey, userDefaults: userDefaults.value)
        }
    }

    // Serial queue ensures writes land in the order they were dispatched, so rapid
    // toggles can't race each other into UserDefaults. Static so all WordsStore
    // instances share one queue (in practice there's one per app, plus per-test).
    private static let persistQueue = DispatchQueue(
        label: "matthewmorrone.Kioku.WordsStore.persist",
        qos: .utility
    )

    // Blocks until every previously dispatched persist write has completed. Used
    // by tests that construct a fresh WordsStore to verify on-disk state — without
    // this, the reader can race past an in-flight background write. Production code
    // never calls this: the next app launch always observes the latest write because
    // the queue drains long before then.
    static func flushPendingWritesForTesting() {
        persistQueue.sync {}
    }
}
