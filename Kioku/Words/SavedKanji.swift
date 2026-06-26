import Foundation

// Represents one saved kanji character — a first-class persistence entity, parallel
// to SavedWord. Identified by its literal (one Unicode kanji scalar), which is also
// the JSON dedup key, so re-saving the same kanji is idempotent.
//
// Distinct from SavedWord because kanji and words are different study objects:
// many useful kanji aren't words on their own (radicals, components, archaic forms),
// and the user typically wants to study a kanji's readings + meanings + stroke order
// rather than a single JMdict entry whose senses depend on the surface form.
// `nonisolated` so CSV import / bulk operations can construct them off-main.
nonisolated struct SavedKanji: Codable, Hashable, Identifiable {
    static let currentSchemaVersion = 1

    // The kanji literal — a single Character expected to satisfy
    // ScriptClassifier.isKanjiScalar. Acts as the stable id, so toggle/save is
    // idempotent across re-presentations of the same KanjiDetailView.
    let literal: String
    // Notes where this kanji was first encountered. Mutable so the user can detach
    // attribution from a single note without rebuilding the record. Mirrors
    // SavedWord.sourceNoteIDs.
    var sourceNoteIDs: [UUID]
    // User-created list memberships, keyed by WordList.id. Reuses WordList /
    // WordListsStore so the same list can mix saved words and saved kanji — the
    // user organizes by topic, not by record type.
    var wordListIDs: [UUID]
    // Free-form personal note attached by the user — mnemonic, study cue, etc.
    var personalNote: String?
    // When the kanji was first saved — drives newest/oldest sort.
    let savedAt: Date

    var id: String { literal }

    // Creates a saved-kanji value. Defaults match the SavedWord pattern: no list
    // / note memberships, savedAt = now. Init is non-private so import paths and
    // tests can construct values from off-main contexts.
    init(
        literal: String,
        sourceNoteIDs: [UUID] = [],
        wordListIDs: [UUID] = [],
        personalNote: String? = nil,
        savedAt: Date = Date()
    ) {
        self.literal = literal
        self.sourceNoteIDs = sourceNoteIDs
        self.wordListIDs = wordListIDs
        self.personalNote = personalNote
        self.savedAt = savedAt
    }

    // Custom decoder so records persisted before optional fields existed load with
    // their defaults rather than failing the whole decode. Mirrors SavedWord's pattern.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        literal = try c.decode(String.self, forKey: .literal)
        sourceNoteIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceNoteIDs) ?? []
        wordListIDs = try c.decodeIfPresent([UUID].self, forKey: .wordListIDs) ?? []
        personalNote = try c.decodeIfPresent(String.self, forKey: .personalNote)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case literal, sourceNoteIDs, wordListIDs, personalNote, savedAt
    }
}
