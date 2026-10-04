import Combine
import Foundation

// Owns the user's learned spellings (LearnedWord). Persists them as JSON in UserDefaults; the set
// is small and edited by hand, one at a time. ContentView watches `words` and rebuilds the read
// resources when it changes, which writes the new set into the dictionary (LearnedWordApplier).
@MainActor
final class LearnedWordStore: ObservableObject {
    static let defaultStorageKey = "kioku.learnedWords.v1"

    @Published private(set) var words: [LearnedWord] = []

    private let defaults: UserDefaults
    private let storageKey: String

    // Takes the defaults and key to persist into so tests can use an isolated suite.
    init(defaults: UserDefaults = .standard, storageKey: String = LearnedWordStore.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        words = Self.load(from: defaults, key: storageKey)
    }

    // Adds a learned spelling, or replaces what an already-learned spelling stands for, so a
    // spelling is never learned twice. Blank spellings are ignored.
    func save(spelling: String, kind: LearnedWordKind) {
        let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if let index = words.firstIndex(where: { $0.spelling == trimmed }) {
            words[index].kind = kind
        } else {
            words.append(LearnedWord(id: UUID(), spelling: trimmed, kind: kind, createdAt: Date()))
        }
        persist()
    }

    // Replaces one learned word in place (edited from the Custom Words screen).
    func update(_ word: LearnedWord) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        words[index] = word
        persist()
    }

    // Forgets a learned spelling; the next resource rebuild removes it from the dictionary.
    func remove(id: UUID) {
        words.removeAll { $0.id == id }
        persist()
    }

    // The learned word for an exact spelling, if any.
    func word(forSpelling spelling: String) -> LearnedWord? {
        words.first { $0.spelling == spelling }
    }

    // Replaces the whole set after a validated backup import.
    func replaceAll(with newWords: [LearnedWord]) {
        words = newWords
        persist()
    }

    // Writes the current set; an encoding failure is logged rather than silently dropped.
    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(words), forKey: storageKey)
        } catch {
            AppLog.error(.dictionary, "LearnedWordStore: encoding failed: \(error)")
        }
    }

    // Reads the persisted set, empty when nothing is stored or the data can't be decoded.
    private static func load(from defaults: UserDefaults, key: String) -> [LearnedWord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([LearnedWord].self, from: data)
        } catch {
            AppLog.error(.dictionary, "LearnedWordStore: decoding failed: \(error)")
            return []
        }
    }
}
