import Foundation

extension DictionaryStore {
    // Fetches the full display bundle for one saved word in a single call.
    // Uses the primary kana form for pitch accent lookup; falls back to surface when no kana form exists.
    // Returns nil when the entry ID is not in the database.
    public func fetchWordDisplayData(entryID: Int64, surface: String) throws -> WordDisplayData? {
        guard let entry = try lookupEntry(entryID: entryID) else { return nil }
        let primaryKana = entry.kanaForms.first?.text ?? surface
        let pitchAccents = try fetchPitchAccent(word: surface, kana: primaryKana)
        let sentences = try fetchSentencePairs(surface: surface)
        return WordDisplayData(entry: entry, pitchAccents: pitchAccents, sentences: sentences)
    }
}
