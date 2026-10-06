import Foundation

// Remembers the English gloss guessed for a surface the dictionary has no entry for, so each
// unknown word costs at most one AI request per line it appears in. Keyed by surface and line,
// since the guess is made from the line and the same spelling can mean different things in
// different lines. Display-only — never read by segmentation or saved-word identity.
//
// `composite` holds the AI meanings of inflected and helper-word forms (起こりそう → "seems likely to
// happen"), keyed by surface and lemma line instead of a line of text: CompositeGlossGuesser asks
// without context, so the lookup sheet and the word detail screen share one answer.
final class GuessedGlossStore {
    static let shared = GuessedGlossStore()
    static let composite = GuessedGlossStore(storageKey: "kioku.lookup.compositeGlosses")

    private let defaults: UserDefaults
    private let storageKey: String

    // Takes the defaults to persist into so tests can use an isolated suite, and the key the map is
    // stored under so the composite meanings keep their own map.
    init(defaults: UserDefaults = .standard, storageKey: String = "kioku.lookup.guessedGlosses") {
        self.defaults = defaults
        self.storageKey = storageKey
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
