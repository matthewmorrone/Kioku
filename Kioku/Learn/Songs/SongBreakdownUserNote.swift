import Foundation

// The optional free-form note a user attaches to a song's breakdown request (e.g. "ignore
// everything in parentheses"), persisted per note in UserDefaults so a Regenerate or Retry
// re-sends the same guidance without retyping it. Kept out of the Note model on purpose: it's
// a request parameter for derived data, not note content, and it must not alter the lyrics
// hash that drives breakdown staleness.
enum SongBreakdownUserNote {
    // Returns the saved note for a song, or "" when none was ever entered.
    static func note(forNoteID id: UUID) -> String {
        UserDefaults.standard.string(forKey: key(id)) ?? ""
    }

    // Saves the note for a song; a blank note removes the key so nothing stale lingers.
    static func setNote(_ note: String, forNoteID id: UUID) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(id))
        } else {
            UserDefaults.standard.set(trimmed, forKey: key(id))
        }
    }

    // UserDefaults key for a song's breakdown note.
    private static func key(_ id: UUID) -> String { "songBreakdown.userNote.\(id.uuidString)" }
}
