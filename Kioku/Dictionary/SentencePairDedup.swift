import Foundation

// Deduplicates a list of SentencePair results from the Tatoeba corpus while
// preserving input order (first occurrence wins). Used wherever sentences are
// surfaced to the user — both per-entry example lists (fetchSentencePairs) and
// free-form sentence search (searchSentences).
//
// Normalization keeps it conservative: trim whitespace, strip a single matching
// pair of wrapping quotes, strip a single trailing sentence-final punctuation
// character. The goal is to catch the punctuation/quote variants the corpus
// actually produces without ever collapsing two semantically different sentences.
// Dedup keys on the normalized Japanese only — different English translations
// of the same Japanese still count as the same example.
nonisolated enum SentencePairDedup {
    // Returns `pairs` with normalized-equivalent Japanese duplicates removed,
    // preserving order.
    static func dedupe(_ pairs: [SentencePair]) -> [SentencePair] {
        var seen = Set<String>()
        var result: [SentencePair] = []
        result.reserveCapacity(pairs.count)
        for pair in pairs {
            let key = normalize(pair.japanese)
            if seen.insert(key).inserted {
                result.append(pair)
            }
        }
        return result
    }

    // Collapses a Japanese sentence to a comparison key by trimming whitespace,
    // unwrapping one balanced pair of sentence-wrapping quotes, and dropping one
    // trailing sentence-final punctuation character. Idempotent.
    private static func normalize(_ text: String) -> String {
        var s = Substring(text)
        // Trim whitespace first so quotes/punctuation we inspect are at the very edges.
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        // Strip one matched pair of wrapping quotes (Japanese kagi, ASCII, curly).
        if let first = s.first, let last = s.last, s.count >= 2, quotePairs[first] == last {
            s = s.dropFirst().dropLast()
            // Re-trim in case there was whitespace inside the quotes.
            while let first = s.first, first.isWhitespace { s = s.dropFirst() }
            while let last = s.last, last.isWhitespace { s = s.dropLast() }
        }
        // Strip one trailing sentence-final punctuation character.
        if let last = s.last, sentenceFinalPunctuation.contains(last) {
            s = s.dropLast()
        }
        return String(s)
    }

    // Maps an opening quote character to its matching closing quote.
    private static let quotePairs: [Character: Character] = [
        "「": "」",
        "『": "』",
        "“": "”",
        "‘": "’",
        "\"": "\"",
        "'": "'",
    ]

    // Sentence-final punctuation that the corpus inconsistently appends.
    private static let sentenceFinalPunctuation: Set<Character> = [
        "。", "．", ".", "！", "!", "？", "?",
    ]
}
