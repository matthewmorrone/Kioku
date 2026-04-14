import Foundation

extension DictionaryStore {
    // Fetches the full display bundle for one saved word in a single call.
    // Uses the primary kana form for pitch accent lookup; falls back to surface when no kana form exists.
    // Searches for example sentences matching the surface and all lemma kanji/kana forms so
    // inflected surfaces still find sentences that use the dictionary form.
    // Returns nil when the entry ID is not in the database.
    public func fetchWordDisplayData(entryID: Int64, surface: String) throws -> WordDisplayData? {
        guard let entry = try lookupEntry(entryID: entryID) else { return nil }
        let primaryKana = entry.kanaForms.first?.text ?? surface
        // Try the inflected surface first; fall back to dictionary kanji/kana forms when the
        // surface is inflected and not present in the pitch accent table (which stores base forms).
        var pitchAccents = try fetchPitchAccent(word: surface, kana: primaryKana)
        if pitchAccents.isEmpty {
            let baseForms = entry.kanjiForms.map(\.text) + entry.kanaForms.map(\.text)
            for form in baseForms {
                pitchAccents = try fetchPitchAccent(word: form, kana: primaryKana)
                if pitchAccents.isEmpty == false { break }
            }
        }

        // Build search terms: surface first (highest priority), then lemma kanji and kana forms.
        var terms = [surface]
        terms += entry.kanjiForms.map(\.text)
        terms += entry.kanaForms.map(\.text)
        let sentences = try fetchSentencePairs(terms: terms)

        return WordDisplayData(entry: entry, pitchAccents: pitchAccents, sentences: sentences)
    }
}
