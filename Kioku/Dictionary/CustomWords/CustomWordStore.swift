import Combine
import Foundation

// Owns the user's Custom Words list (CustomWord): the built-in defaults the app ships
// (Resources/extras.json, bundledDefaults) plus the user's own additions and edits. Persisted as JSON
// in UserDefaults; included in backups. ContentView syncs the built-ins at launch and rebuilds the
// read resources when `words` changes, which writes the list into the dictionary (CustomWordApplier).
@MainActor
final class CustomWordStore: ObservableObject {
    static let defaultStorageKey = "kioku.customWords.v1"

    @Published private(set) var words: [CustomWord] = []
    // The built-ins this app ships, by key (headword, or "sameAs <ent_seq> <spelling>" for a link):
    // a default the user deleted is never re-added, and Restore Defaults resets to these.
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

    // The built-in Custom Words shipped in the app bundle (Resources/extras.json), keyed: a word by
    // its headword, a "same word as" spelling by its target and spelling. Empty, logged, when the
    // file is missing or unreadable.
    nonisolated static func bundledDefaults(bundle: Bundle = .main) -> [CustomWord] {
        guard let url = bundle.url(forResource: "extras", withExtension: "json") else {
            AppLog.error(.dictionary, "Built-in Custom Words: extras.json not in the bundle")
            return []
        }
        do {
            return try CustomWordsExtrasCodec.decode(Data(contentsOf: url)).map { word in
                var word = word
                if let sameAs = word.sameAsEntSeq {
                    word.defaultKey = "sameAs \(sameAs) \(CustomWordIdentity.headword(of: word))"
                } else {
                    word.defaultKey = CustomWordIdentity.headword(of: word)
                }
                return word
            }
        } catch {
            AppLog.error(.dictionary, "Built-in Custom Words unreadable: \(error)")
            return []
        }
    }

    // Makes the offered defaults exactly `builtIns`: ones never offered are added to the list, ones
    // no longer built in are forgotten as defaults (Restore Defaults then removes them), and the
    // rest keep whatever the user did with them.
    func syncBuiltIns(_ builtIns: [CustomWord]) {
        var byKey: [String: CustomWord] = [:]
        for word in builtIns {
            if let key = word.defaultKey, byKey[key] == nil { byKey[key] = word }
        }
        for (key, word) in byKey.sorted(by: { $0.key < $1.key }) where offeredDefaults[key] == nil {
            words.append(word)
        }
        guard byKey != offeredDefaults else { return }
        offeredDefaults = byKey
        persist()
    }

    // Resets the list to the built-ins: deleted ones re-added, edited ones reset, and words from
    // built-ins the app no longer ships removed. The user's own words stay.
    func restoreDefaults() {
        words.removeAll { word in word.defaultKey.map { offeredDefaults[$0] == nil } ?? false }
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
