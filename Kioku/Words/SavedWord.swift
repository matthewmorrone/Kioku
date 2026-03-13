import Foundation

// Represents one saved word, optionally linked to the note where it was starred.
struct SavedWord: Codable, Hashable {
    let canonicalEntryID: Int64
    let surface: String
    let sourceNoteID: UUID?

    // Keeps saved-word identity stable across surface variants that map to the same dictionary entry.
    static func == (lhs: SavedWord, rhs: SavedWord) -> Bool {
        lhs.canonicalEntryID == rhs.canonicalEntryID
    }

    // Hashes by canonical entry identity so sets and dictionaries are keyed by dictionary entry id.
    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalEntryID)
    }
}
