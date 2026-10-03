import Foundation

// Remembers the English gloss guessed for a surface the dictionary has no entry for, so each
// unknown word costs at most one AI request per line it appears in. Keyed by surface and line,
// since the guess is made from the line and the same spelling can mean different things in
// different lines. Display-only — never read by segmentation or saved-word identity.
final class GuessedGlossStore {
    static let shared = GuessedGlossStore()

    private let defaults: UserDefaults
    private let storageKey = "kioku.lookup.guessedGlosses"

    // Takes the defaults to persist into so tests can use an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // The stored guess for `surface` in `line`, or nil when none has been made yet.
    func gloss(for surface: String, in line: String) -> String? {
        storedGlosses()[key(surface: surface, line: line)]
    }

    // Stores a guess for `surface` in `line`, replacing any earlier one. Blank guesses are not stored.
    func setGloss(_ gloss: String, for surface: String, in line: String) {
        let trimmed = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, surface.isEmpty == false else { return }
        var glosses = storedGlosses()
        glosses[key(surface: surface, line: line)] = trimmed
        defaults.set(glosses, forKey: storageKey)
    }

    // Joins surface and line with a unit separator, which neither contains.
    private func key(surface: String, line: String) -> String {
        surface + "\u{1F}" + line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Reads the whole surface → gloss map, empty when nothing has been stored.
    private func storedGlosses() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
}
