import Foundation

// Remembers the English gloss guessed for a surface the dictionary has no entry for, so each
// unknown word costs at most one AI request. Keyed by surface alone: a guess is shown as a guess
// and only stands in for a missing entry, so one per written form is enough. Display-only — never
// read by segmentation or saved-word identity.
final class GuessedGlossStore {
    static let shared = GuessedGlossStore()

    private let defaults: UserDefaults
    private let storageKey = "kioku.lookup.guessedGlosses"

    // Takes the defaults to persist into so tests can use an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // The stored guess for `surface`, or nil when none has been made yet.
    func gloss(for surface: String) -> String? {
        storedGlosses()[surface]
    }

    // Stores a guess for `surface`, replacing any earlier one. Blank guesses are not stored.
    func setGloss(_ gloss: String, for surface: String) {
        let trimmed = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, surface.isEmpty == false else { return }
        var glosses = storedGlosses()
        glosses[surface] = trimmed
        defaults.set(glosses, forKey: storageKey)
    }

    // Reads the whole surface → gloss map, empty when nothing has been stored.
    private func storedGlosses() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
