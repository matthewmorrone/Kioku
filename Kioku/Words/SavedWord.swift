import Foundation

// Represents one saved word that can belong to multiple note-linked lists and user-created word lists.
struct SavedWord: Codable, Hashable, Identifiable {
    let canonicalEntryID: Int64
    let surface: String
    // Provenance: which notes this word was saved from. Not used for list-membership UI.
    let sourceNoteIDs: [UUID]
    // User-created word list memberships, keyed by WordList.id.
    var wordListIDs: [UUID]
    // When the word was first saved — used for newest/oldest sort. Defaults to distantPast for migrated records.
    let savedAt: Date

    var id: Int64 {
        canonicalEntryID
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalEntryID
        case surface
        case sourceNoteID
        case sourceNoteIDs
        case wordListIDs
        case savedAt
    }

    // Creates a saved-word value with optional note-list and word-list memberships.
    init(canonicalEntryID: Int64, surface: String, sourceNoteIDs: [UUID] = [], wordListIDs: [UUID] = [], savedAt: Date = Date()) {
        self.canonicalEntryID = canonicalEntryID
        self.surface = surface
        self.sourceNoteIDs = sourceNoteIDs
        self.wordListIDs = wordListIDs
        self.savedAt = savedAt
    }

    // Decodes both current many-to-many payloads and legacy single-note payloads. Defaults wordListIDs to [] when absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalEntryID = try container.decode(Int64.self, forKey: .canonicalEntryID)
        surface = try container.decode(String.self, forKey: .surface)
        wordListIDs = try container.decodeIfPresent([UUID].self, forKey: .wordListIDs) ?? []
        savedAt = try container.decode(Date.self, forKey: .savedAt)

        if let decodedSourceNoteIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceNoteIDs) {
            sourceNoteIDs = decodedSourceNoteIDs
            return
        }

        if let legacySourceNoteID = try container.decodeIfPresent(UUID.self, forKey: .sourceNoteID) {
            sourceNoteIDs = [legacySourceNoteID]
            return
        }

        sourceNoteIDs = []
    }

    // Encodes canonical saved-word payloads including note-list and word-list memberships.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalEntryID, forKey: .canonicalEntryID)
        try container.encode(surface, forKey: .surface)
        try container.encode(sourceNoteIDs, forKey: .sourceNoteIDs)
        try container.encode(wordListIDs, forKey: .wordListIDs)
        try container.encode(savedAt, forKey: .savedAt)
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
