import Foundation

// invariant-store-test-coverage: SavedKanjiStoreTests.swift

// Loads and persists saved kanji to UserDefaults as JSON-encoded SavedKanji arrays.
// Mirrors SavedWordStorage's pattern (encode/decode, normalize-on-load) so the two
// stores behave identically to operations, tests, and backups.
nonisolated enum SavedKanjiStorage {
    static let defaultStorageKey = "kioku.savedKanji.v1"

    // Loads saved kanji from storage and rewrites them if normalization (dedup by
    // literal, merge list/note memberships) changes the payload. Returning the
    // normalized form ensures the in-memory snapshot matches what's on disk.
    static func loadSavedKanji(
        storageKey: String,
        userDefaults: UserDefaults = .standard
    ) -> [SavedKanji] {
        guard let decoded = UserDefaultsJSON.load([SavedKanji].self, forKey: storageKey, from: userDefaults, logAs: .storage) else {
            return []
        }
        let normalized = normalizedEntries(decoded)
        writeNormalized(normalized, storageKey: storageKey, userDefaults: userDefaults)
        return normalized
    }

    // Persists saved kanji after deduplicating by literal. Used by external writers
    // (e.g. CSV import, bulk operations) that may produce duplicate records.
    static func persist(entries: [SavedKanji], storageKey: String, userDefaults: UserDefaults = .standard) {
        writeNormalized(normalizedEntries(entries), storageKey: storageKey, userDefaults: userDefaults)
    }

    // Encodes and writes an already-normalized array. Used by SavedKanjiStore when
    // it has just normalized and wants to publish to memory + disk in one step.
    static func writeNormalized(_ normalized: [SavedKanji], storageKey: String, userDefaults: UserDefaults = .standard) {
        UserDefaultsJSON.save(normalized, forKey: storageKey, to: userDefaults, logAs: .storage)
    }

    // Coalesces duplicate saves by kanji literal while preserving first-seen order.
    // For each duplicate group: keep the earliest savedAt + first non-empty
    // personalNote, union sourceNoteIDs and wordListIDs (so re-saving a kanji from
    // a different note adds attribution rather than overwriting it).
    static func normalizedEntries(_ entries: [SavedKanji]) -> [SavedKanji] {
        var mergedByLiteral: [String: SavedKanji] = [:]
        var orderedLiterals: [String] = []

        for entry in entries {
            if var existing = mergedByLiteral[entry.literal] {
                let mergedSourceNoteIDs = Array(Set(existing.sourceNoteIDs).union(entry.sourceNoteIDs)).sorted { $0.uuidString < $1.uuidString }
                let mergedListIDs = Array(Set(existing.wordListIDs).union(entry.wordListIDs)).sorted { $0.uuidString < $1.uuidString }
                let mergedNote = existing.personalNote ?? entry.personalNote
                let earliestSavedAt = min(existing.savedAt, entry.savedAt)
                existing = SavedKanji(
                    literal: existing.literal,
                    sourceNoteIDs: mergedSourceNoteIDs,
                    wordListIDs: mergedListIDs,
                    personalNote: mergedNote,
                    savedAt: earliestSavedAt
                )
                mergedByLiteral[entry.literal] = existing
            } else {
                mergedByLiteral[entry.literal] = entry
                orderedLiterals.append(entry.literal)
            }
        }
        return orderedLiterals.compactMap { mergedByLiteral[$0] }
    }
}
