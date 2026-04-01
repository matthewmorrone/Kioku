import Foundation

// Loads and persists saved words in canonical-entry keyed normalized form.
enum SavedWordStorage {
    // Loads saved words from storage and rewrites them if normalization changes the payload.
    static func loadSavedWords(
        storageKey: String,
        userDefaults: UserDefaults = .standard
    ) -> [SavedWord] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decodedEntries = try? JSONDecoder().decode([SavedWord].self, from: data) else {
            return []
        }

        let normalizedEntries = normalizedEntries(decodedEntries)
        if let normalizedData = try? JSONEncoder().encode(normalizedEntries), normalizedData != data {
            userDefaults.set(normalizedData, forKey: storageKey)
        }
        return normalizedEntries
    }

    // Persists saved words after coalescing duplicates by canonical entry id.
    static func persist(entries: [SavedWord], storageKey: String, userDefaults: UserDefaults = .standard) {
        let normalized = normalizedEntries(entries)
        if let encoded = try? JSONEncoder().encode(normalized) {
            userDefaults.set(encoded, forKey: storageKey)
        }
    }

    // Coalesces duplicate saves by canonical entry id while preserving first-seen order.
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
                    wordListIDs: mergedWordListIDs,
                    savedAt: existing.savedAt
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
