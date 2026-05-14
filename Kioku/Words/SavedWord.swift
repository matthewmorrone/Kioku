import Foundation

// Points to a single gloss within a sense — used when the user wants a flashcard meaning to be
// one specific synonym rather than the sense's first-gloss-as-representative.
nonisolated struct GlossRef: Codable, Hashable {
    let senseID: Int64
    let glossIndex: Int
}

// Represents one saved word that can belong to multiple note-linked lists and user-created word lists.
// `nonisolated` so import pipelines (CSV, bulk) can construct it from detached tasks.
nonisolated struct SavedWord: Codable, Hashable, Identifiable {
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
    // Whole-sense selections. Mutually exclusive with selectedGlosses *for the same sense* —
    // see WordsStore.applySelection for the enforced invariant. Empty means "no whole-sense
    // selections."
    var selectedSenseIDs: [Int64]
    // Gloss-level selections — one entry per specific synonym the user pinned. Mutually
    // exclusive with selectedSenseIDs at the sense granularity (see invariant above).
    var selectedGlosses: [GlossRef]

    var id: Int64 {
        canonicalEntryID
    }

    // Creates a saved-word value with optional note-list and word-list memberships.
    init(canonicalEntryID: Int64, surface: String, sourceNoteIDs: [UUID] = [], wordListIDs: [UUID] = [], personalNote: String? = nil, savedAt: Date = Date(), selectedSenseIDs: [Int64] = [], selectedGlosses: [GlossRef] = []) {
        self.canonicalEntryID = canonicalEntryID
        self.surface = surface
        self.sourceNoteIDs = sourceNoteIDs
        self.wordListIDs = wordListIDs
        self.personalNote = personalNote
        self.savedAt = savedAt
        self.selectedSenseIDs = selectedSenseIDs
        self.selectedGlosses = selectedGlosses
    }

    // Custom decoder so saves persisted before the selection fields existed load with [].
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canonicalEntryID = try c.decode(Int64.self, forKey: .canonicalEntryID)
        surface = try c.decode(String.self, forKey: .surface)
        sourceNoteIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceNoteIDs) ?? []
        wordListIDs = try c.decodeIfPresent([UUID].self, forKey: .wordListIDs) ?? []
        personalNote = try c.decodeIfPresent(String.self, forKey: .personalNote)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        selectedSenseIDs = try c.decodeIfPresent([Int64].self, forKey: .selectedSenseIDs) ?? []
        selectedGlosses = try c.decodeIfPresent([GlossRef].self, forKey: .selectedGlosses) ?? []
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
