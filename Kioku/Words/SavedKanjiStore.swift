import Foundation
import Combine

// In-memory + on-disk store for saved kanji. ObservableObject so SwiftUI views
// react to changes; UserDefaults-backed via SavedKanjiStorage. Mirrors WordsStore
// for SavedWord (including @MainActor isolation) so any UI pattern (filtering by
// list, batch select, etc.) that works on words can apply to kanji with the same
// shape.
@MainActor
final class SavedKanjiStore: ObservableObject {
    @Published private(set) var kanji: [SavedKanji] = []

    // nonisolated(unsafe) for the same reason as WordsStore — UserDefaults isn't
    // formally Sendable but is documented thread-safe in practice. Both the suite
    // and the storage key are injectable so tests scope to a per-case UD instance.
    nonisolated(unsafe) private let userDefaults: UserDefaults
    nonisolated private let storageKey: String

    // Wraps UserDefaults in an unchecked-Sendable box so the persistQueue capture
    // satisfies Swift 6 strict-concurrency. Same pattern as WordsStore.
    nonisolated private let userDefaultsBox: UncheckedSendableUserDefaults

    // Initializes the store, loading any existing saved kanji from UserDefaults.
    // Storage key defaults to the production key; tests inject a per-suite key so
    // they don't trample one another or the real app data.
    init(userDefaults: UserDefaults = .standard, storageKey: String = SavedKanjiStorage.defaultStorageKey) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.userDefaultsBox = UncheckedSendableUserDefaults(value: userDefaults)
        self.kanji = SavedKanjiStorage.loadSavedKanji(storageKey: storageKey, userDefaults: userDefaults)
    }

    // True when `literal` is already saved. Used by KanjiDetailView's star button
    // to render filled/unfilled state, and by Words tab UIs that mark already-saved
    // results to avoid presenting the same kanji as a fresh save option.
    func contains(literal: String) -> Bool {
        kanji.contains { $0.literal == literal }
    }

    // Looks up the saved record for a literal, if any. Lets callers read list
    // memberships / personal notes without filtering manually.
    func savedKanji(for literal: String) -> SavedKanji? {
        kanji.first { $0.literal == literal }
    }

    // Toggles a kanji's saved state. Returns true if the kanji is now saved.
    // Attribution: when adding, the sourceNoteID (if any) is recorded so the kanji
    // remembers which note surfaced it; when removing, the entire record is dropped.
    @discardableResult
    func toggle(literal: String, sourceNoteID: UUID? = nil) -> Bool {
        if let index = kanji.firstIndex(where: { $0.literal == literal }) {
            kanji.remove(at: index)
            persist()
            return false
        } else {
            let entry = SavedKanji(
                literal: literal,
                sourceNoteIDs: sourceNoteID.map { [$0] } ?? [],
                wordListIDs: []
            )
            kanji.append(entry)
            persist()
            return true
        }
    }

    // Saves a kanji unconditionally — used by CSV import where the user has
    // already declared intent (and toggling would surprise-remove an existing
    // save). Existing records have their attribution unioned; new records are
    // created with the provided defaults.
    func save(literal: String, sourceNoteIDs: [UUID] = [], wordListIDs: [UUID] = [], personalNote: String? = nil) {
        if let index = kanji.firstIndex(where: { $0.literal == literal }) {
            var existing = kanji[index]
            let mergedSourceNotes = Array(Set(existing.sourceNoteIDs).union(sourceNoteIDs))
            let mergedListIDs = Array(Set(existing.wordListIDs).union(wordListIDs))
            existing = SavedKanji(
                literal: existing.literal,
                sourceNoteIDs: mergedSourceNotes,
                wordListIDs: mergedListIDs,
                personalNote: existing.personalNote ?? personalNote,
                savedAt: existing.savedAt
            )
            kanji[index] = existing
        } else {
            kanji.append(SavedKanji(
                literal: literal,
                sourceNoteIDs: sourceNoteIDs,
                wordListIDs: wordListIDs,
                personalNote: personalNote
            ))
        }
        persist()
    }

    // Strips a deleted list id from every saved kanji so no stale memberships
    // remain — mirrors WordsStore.removeListMembership(listID:). Called from
    // the list-delete confirmation in WordsFilterView so SavedWord AND
    // SavedKanji members of the deleted list both get cleaned up.
    func removeListMembership(listID: UUID) {
        var anyChanged = false
        kanji = kanji.map { entry in
            guard entry.wordListIDs.contains(listID) else { return entry }
            anyChanged = true
            var updated = entry.wordListIDs
            updated.removeAll { $0 == listID }
            return SavedKanji(
                literal: entry.literal,
                sourceNoteIDs: entry.sourceNoteIDs,
                wordListIDs: updated,
                personalNote: entry.personalNote,
                savedAt: entry.savedAt
            )
        }
        if anyChanged { persist() }
    }

    // Strips deleted note ids from every saved kanji's sourceNoteIDs — mirrors
    // WordsStore.detachNoteReferences(noteIDs:). Called when notes are deleted
    // so the "first encountered in note X" attribution doesn't dangle.
    func detachNoteReferences(noteIDs: Set<UUID>) {
        guard noteIDs.isEmpty == false else { return }
        var anyChanged = false
        kanji = kanji.map { entry in
            let intersection = Set(entry.sourceNoteIDs).intersection(noteIDs)
            guard intersection.isEmpty == false else { return entry }
            anyChanged = true
            var updated = entry.sourceNoteIDs
            updated.removeAll { intersection.contains($0) }
            return SavedKanji(
                literal: entry.literal,
                sourceNoteIDs: updated,
                wordListIDs: entry.wordListIDs,
                personalNote: entry.personalNote,
                savedAt: entry.savedAt
            )
        }
        if anyChanged { persist() }
    }

    // Removes a saved kanji record by literal. Safe no-op when the literal isn't
    // currently saved — the call-site doesn't need to pre-check.
    func remove(literal: String) {
        guard let index = kanji.firstIndex(where: { $0.literal == literal }) else { return }
        kanji.remove(at: index)
        persist()
    }

    // Adds or removes a kanji from a user-created word list. Idempotent on both
    // axes — adding an already-member literal or removing a non-member is a no-op.
    func setListMembership(literal: String, listID: UUID, isMember: Bool) {
        guard let index = kanji.firstIndex(where: { $0.literal == literal }) else { return }
        var entry = kanji[index]
        var members = Set(entry.wordListIDs)
        if isMember {
            members.insert(listID)
        } else {
            members.remove(listID)
        }
        entry = SavedKanji(
            literal: entry.literal,
            sourceNoteIDs: entry.sourceNoteIDs,
            wordListIDs: Array(members).sorted { $0.uuidString < $1.uuidString },
            personalNote: entry.personalNote,
            savedAt: entry.savedAt
        )
        kanji[index] = entry
        persist()
    }

    // Updates the personal note on a saved kanji. Passing nil or empty clears it
    // (decoded as nil on next load via the optional CodingKey).
    func setPersonalNote(literal: String, note: String?) {
        guard let index = kanji.firstIndex(where: { $0.literal == literal }) else { return }
        var entry = kanji[index]
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry = SavedKanji(
            literal: entry.literal,
            sourceNoteIDs: entry.sourceNoteIDs,
            wordListIDs: entry.wordListIDs,
            personalNote: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            savedAt: entry.savedAt
        )
        kanji[index] = entry
        persist()
    }

    // Reloads the published kanji array from persistent storage. Called by external
    // writers that bypass the store (none today, but mirrors WordsStore.reload for
    // symmetry and future bulk-import paths).
    func reload() {
        kanji = SavedKanjiStorage.loadSavedKanji(storageKey: storageKey, userDefaults: userDefaults)
    }

    // Persists the current in-memory snapshot off-main on persistQueue. Mirrors
    // WordsStore's pattern — star-toggles return immediately, the disk write
    // happens shortly after on a serial queue so concurrent toggles can't race.
    private func persist() {
        let snapshot = kanji
        let storageKey = self.storageKey
        let userDefaults = self.userDefaultsBox
        SavedKanjiStore.persistQueue.async {
            SavedKanjiStorage.writeNormalized(snapshot, storageKey: storageKey, userDefaults: userDefaults.value)
        }
    }

    // Shared serial queue for off-main writes. Utility QoS keeps it out of the way
    // of UI work; serial ordering means concurrent toggles persist in caller order
    // without locking.
    private static let persistQueue = DispatchQueue(
        label: "kioku.savedKanji.persist",
        qos: .utility
    )

    // Synchronously flushes pending writes. Tests call this after a toggle/save
    // to make assertions on the persisted state without polling.
    func flushPendingWritesForTesting() {
        SavedKanjiStore.persistQueue.sync {}
    }
}
