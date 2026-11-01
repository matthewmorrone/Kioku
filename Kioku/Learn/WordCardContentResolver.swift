import Foundation

// Resolves a saved word's headword, reading and meanings from the dictionary. Flashcards, Spotlight
// and the Anki export all show the same card content, so it is derived here once (AGENTS.md
// invariant 12) instead of in each view.
//
// `nonisolated` and synchronous: callers run it off the main actor themselves.
nonisolated enum WordCardContentResolver {
    // Builds the card content for `word`, or nil when the entry is missing from the dictionary.
    // Meanings combine whole-sense selections (the sense's first gloss) with gloss-level picks (that
    // exact gloss), dropping duplicates; with no selection the entry's first gloss stands in.
    static func resolve(word: SavedWord, store: DictionaryStore) -> WordCardContent? {
        let entry: DictionaryEntry
        do {
            guard let found = try store.lookupEntry(entryID: word.canonicalEntryID) else { return nil }
            entry = found
        } catch {
            AppLog.error(.dictionary, "[WordCardContentResolver] lookup failed for entry \(word.canonicalEntryID): \(error)")
            return nil
        }
        return resolve(word: word, entry: entry, store: store)
    }

    // The same content from an entry the caller already fetched — the Anki export fetches entries in
    // batches rather than one query per word.
    static func resolve(word: SavedWord, entry: DictionaryEntry, store: DictionaryStore) -> WordCardContent {
        let forms = WordFormResolver.kanjiAndKana(
            entry: entry, store: store, entryID: word.canonicalEntryID,
            selectedSenseIDs: word.selectedSenseIDs, selectedGlosses: word.selectedGlosses,
            chosenReading: word.selectedReading
        )
        return WordCardContent(
            surface: word.surface,
            kanji: forms.kanji,
            kana: forms.kana,
            meanings: meanings(
                entry: entry,
                selectedSenseIDs: word.selectedSenseIDs,
                selectedGlosses: word.selectedGlosses
            )
        )
    }

    // The ordered, de-duplicated meaning strings for the given selections; falls back to the first
    // sense's first gloss when nothing selected survives (e.g. after a dictionary rebuild).
    static func meanings(
        entry: DictionaryEntry,
        selectedSenseIDs: [Int64],
        selectedGlosses: [GlossRef]
    ) -> [String] {
        var sensesByID: [Int64: DictionaryEntrySense] = [:]
        for sense in entry.senses { sensesByID[sense.senseID] = sense }

        var result: [String] = []
        var seen: Set<String> = []

        // Adds a meaning after trimming and de-duplicating.
        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else { return }
            result.append(trimmed)
        }

        for senseID in selectedSenseIDs {
            if let first = sensesByID[senseID]?.glosses.first { append(first) }
        }
        for ref in selectedGlosses {
            if let sense = sensesByID[ref.senseID], ref.glossIndex >= 0, ref.glossIndex < sense.glosses.count {
                append(sense.glosses[ref.glossIndex])
            }
        }
        if result.isEmpty, let first = entry.senses.first?.glosses.first { append(first) }
        return result
    }
}
