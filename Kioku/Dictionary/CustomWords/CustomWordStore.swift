import Combine
import Foundation

// Owns the user's Custom Words list (CustomWord): the dictionary's extras.json defaults plus the
// user's own additions and edits. Persisted as JSON in UserDefaults; included in backups. ContentView
// rebuilds the read resources when `words` changes, which writes the list into the dictionary
// (CustomWordApplier) and reports any defaults a newer dictionary brought, added here by addDefaults.
@MainActor
final class CustomWordStore: ObservableObject {
    static let defaultStorageKey = "kioku.customWords.v1"

    @Published private(set) var words: [CustomWord] = []
    // Defaults already offered, by headword, as first seen: a default the user deleted or edited is
    // never re-added by a later dictionary, and Restore Defaults brings back these originals.
    @Published private(set) var offeredDefaults: [String: CustomWord] = [:]

    private let defaults: UserDefaults
    private let storageKey: String

    // Takes the defaults and key to persist into so tests can use an isolated suite.
    init(defaults: UserDefaults = .standard, storageKey: String = CustomWordStore.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        let state = Self.load(from: defaults, key: storageKey)
        words = state.words
        offeredDefaults = state.offeredDefaults
    }

    // The persisted state as one value, for backups.
    var state: CustomWordStoreState {
        CustomWordStoreState(words: words, offeredDefaults: offeredDefaults)
    }

    // Adds a word, or replaces the one with the same id. A new word gets its stable ent_seq here.
    func save(_ word: CustomWord) {
        var word = word
        if word.sameAsEntSeq == nil, word.entSeq == nil {
            word.entSeq = CustomWordIdentity.entSeq(forHeadword: CustomWordIdentity.headword(of: word))
        }
        if let index = words.firstIndex(where: { $0.id == word.id }) {
            words[index] = word
        } else {
            words.append(word)
        }
        persist()
    }

    // Deletes a word; the next resource rebuild removes it from the dictionary.
    func remove(id: UUID) {
        words.removeAll { $0.id == id }
        persist()
    }

    // Adds defaults a dictionary carried that haven't been offered before, remembering them so a
    // later deletion sticks.
    func addDefaults(_ newDefaults: [CustomWord]) {
        var added = false
        for word in newDefaults {
            guard let key = word.defaultKey, offeredDefaults[key] == nil else { continue }
            offeredDefaults[key] = word
            words.append(word)
            added = true
        }
        if added { persist() }
    }

    // Brings back every offered default the list no longer has in its original form: deleted ones
    // are re-added, edited ones reset.
    func restoreDefaults() {
        for (key, original) in offeredDefaults.sorted(by: { $0.key < $1.key }) {
            if let index = words.firstIndex(where: { $0.defaultKey == key }) {
                words[index] = original
            } else {
                words.append(original)
            }
        }
        persist()
    }

    // Puts the list back to exactly the offered defaults (Erase All Data).
    func resetToDefaults() {
        words = offeredDefaults.keys.sorted().compactMap { offeredDefaults[$0] }
        persist()
    }

    // Replaces the list with an imported extras.json's words. Offered defaults are kept, so the
    // dictionary's defaults the import leaves out stay deleted.
    func replaceWords(with newWords: [CustomWord]) {
        words = newWords.map { word in
            var word = word
            if word.sameAsEntSeq == nil, word.entSeq == nil {
                word.entSeq = CustomWordIdentity.entSeq(forHeadword: CustomWordIdentity.headword(of: word))
            }
            return word
        }
        persist()
    }

    // Replaces everything after a validated backup import.
    func replaceAll(with state: CustomWordStoreState) {
        words = state.words
        offeredDefaults = state.offeredDefaults
        persist()
    }

    // Writes the current state; an encoding failure is logged rather than silently dropped.
    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(state), forKey: storageKey)
        } catch {
            AppLog.error(.dictionary, "CustomWordStore: encoding failed: \(error)")
        }
    }

    // Reads the persisted state, empty when nothing is stored or the data can't be decoded.
    private static func load(from defaults: UserDefaults, key: String) -> CustomWordStoreState {
        let empty = CustomWordStoreState(words: [], offeredDefaults: [:])
        guard let data = defaults.data(forKey: key) else { return empty }
        do {
            return try JSONDecoder().decode(CustomWordStoreState.self, from: data)
        } catch {
            AppLog.error(.dictionary, "CustomWordStore: decoding failed: \(error)")
            return empty
        }
    }
}
