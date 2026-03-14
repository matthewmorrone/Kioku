import Foundation

// Represents one saved word that can belong to multiple note-linked lists.
struct SavedWord: Codable, Hashable, Identifiable {
    let canonicalEntryID: Int64
    let surface: String
    let sourceNoteIDs: [UUID]

    var id: Int64 {
        canonicalEntryID
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalEntryID
        case surface
        case sourceNoteID
        case sourceNoteIDs
    }

    // Creates a saved-word value with optional note-list memberships.
    init(canonicalEntryID: Int64, surface: String, sourceNoteIDs: [UUID] = []) {
        self.canonicalEntryID = canonicalEntryID
        self.surface = surface
        self.sourceNoteIDs = sourceNoteIDs
    }

    // Decodes both current many-to-many payloads and legacy single-note payloads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalEntryID = try container.decode(Int64.self, forKey: .canonicalEntryID)
        surface = try container.decode(String.self, forKey: .surface)

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

    // Encodes canonical saved-word payloads including note-list memberships.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalEntryID, forKey: .canonicalEntryID)
        try container.encode(surface, forKey: .surface)
        try container.encode(sourceNoteIDs, forKey: .sourceNoteIDs)
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
