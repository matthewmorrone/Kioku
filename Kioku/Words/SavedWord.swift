import Foundation

// Represents one saved word that can belong to multiple note-linked lists and user-created word lists.
struct SavedWord: Codable, Hashable, Identifiable {
    static let currentSchemaVersion = 1

    let canonicalEntryID: Int64
    let surface: String
    // Provenance: which notes this word was saved from. Not used for list-membership UI.
    let sourceNoteIDs: [UUID]
    // User-created word list memberships, keyed by WordList.id.
    var wordListIDs: [UUID]
    // Free-form personal note attached by the user — mnemonic, context, etc.
    var personalNote: String?
    // When the word was first saved — used for newest/oldest sort.
    let savedAt: Date

    var id: Int64 {
        canonicalEntryID
    }

    // Creates a saved-word value with optional note-list and word-list memberships.
    init(canonicalEntryID: Int64, surface: String, sourceNoteIDs: [UUID] = [], wordListIDs: [UUID] = [], personalNote: String? = nil, savedAt: Date = Date()) {
        self.canonicalEntryID = canonicalEntryID
        self.surface = surface
        self.sourceNoteIDs = sourceNoteIDs
        self.wordListIDs = wordListIDs
        self.personalNote = personalNote
        self.savedAt = savedAt
    }

    // Keeps saved-word identity stable across surface variants that map to the same dictionary entry.
    static func == (lhs: SavedWord, rhs: SavedWord) -> Bool {
        lhs.canonicalEntryID == rhs.canonicalEntryID
    }

    // Hashes by canonical entry identity so sets and dictionaries are keyed by dictionary entry id.
    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalEntryID)
    }
}
