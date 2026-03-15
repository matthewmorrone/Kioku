import Foundation

// Loads and persists canonical-entry keyed saved words in normalized form.
struct SavedWordStorageMigrator {
    // Loads canonical saved words from storage and rewrites them in normalized form.
    static func loadSavedWords(
        storageKey: String,
        userDefaults: UserDefaults = .standard
    ) -> [SavedWord] {
        if let data = userDefaults.data(forKey: storageKey) {
            if let decodedEntries = try? JSONDecoder().decode([SavedWord].self, from: data) {
                let normalizedEntries = normalizedEntries(decodedEntries)
                if let normalizedData = try? JSONEncoder().encode(normalizedEntries), normalizedData != data {
                    userDefaults.set(normalizedData, forKey: storageKey)
                }
                return normalizedEntries
            }
        }

        return []
    }

    // Persists saved-word entries as normalized canonical-entry keyed payloads.
    static func persist(entries: [SavedWord], storageKey: String, userDefaults: UserDefaults = .standard) {
        let normalized = normalizedEntries(entries)
        if let encoded = try? JSONEncoder().encode(normalized) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }

    // Coalesces duplicate saves by canonical entry id while preserving first-seen order.
    // wordListIDs are unioned across duplicates so list membership is never dropped.
    static func normalizedEntries(_ entries: [SavedWord]) -> [SavedWord] {
        var mergedByEntryID: [Int64: SavedWord] = [:]
        var orderedEntryIDs: [Int64] = []

        for entry in entries {
            if var existing = mergedByEntryID[entry.canonicalEntryID] {
                let preferredSurface = existing.surface.isEmpty ? entry.surface : existing.surface
                let mergedSourceNoteIDs = Array(Set(existing.sourceNoteIDs).union(entry.sourceNoteIDs)).sorted { lhs, rhs in
                    lhs.uuidString < rhs.uuidString
                }
                let mergedWordListIDs = Array(Set(existing.wordListIDs).union(entry.wordListIDs)).sorted { lhs, rhs in
                    lhs.uuidString < rhs.uuidString
                }
                existing = SavedWord(
                    canonicalEntryID: existing.canonicalEntryID,
                    surface: preferredSurface,
                    sourceNoteIDs: mergedSourceNoteIDs,
                    wordListIDs: mergedWordListIDs
                )
                mergedByEntryID[entry.canonicalEntryID] = existing
                continue
            }

            mergedByEntryID[entry.canonicalEntryID] = entry
            orderedEntryIDs.append(entry.canonicalEntryID)
        }

        return orderedEntryIDs.compactMap { mergedByEntryID[$0] }
    }
}
