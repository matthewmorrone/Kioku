import Foundation

// Routes example sentences to the dictionary sense each one most likely demonstrates, using
// gloss-word overlap on the English translation. Sentences that don't strongly match any single
// sense (zero overlap, or a tie between two senses) land in the `unrouted` bucket.
// Heuristic only — Tatoeba sentences don't carry sense indices in JMdict, and this avoids
// importing a separate tagged corpus.
nonisolated enum SentenceSenseRouter {
    // The result of routing: per-sense buckets plus a fallback bucket for ambiguous sentences.
    struct Routing: Equatable {
        let bySense: [Int64: [SentencePair]]
        let unrouted: [SentencePair]
    }

    // Computes the routing. Per-sense buckets are capped at `maxPerSense` (preserving input order).
    static func route(
        sentences: [SentencePair],
        senses: [DictionaryEntrySense],
        maxPerSense: Int = 2
    ) -> Routing {
        guard senses.isEmpty == false else {
            return Routing(bySense: [:], unrouted: sentences)
        }

        // Pre-tokenize each sense's glosses so we tokenize each sense once, not per sentence.
        let senseTokens: [(senseID: Int64, tokens: Set<String>)] = senses.map { sense in
            var bag = Set<String>()
            for gloss in sense.glosses {
                bag.formUnion(meaningfulTokens(in: gloss))
            }
            return (sense.senseID, bag)
        }

        var bySense: [Int64: [SentencePair]] = [:]
        var unrouted: [SentencePair] = []

        for sentence in sentences {
            let sentenceTokens = meaningfulTokens(in: sentence.english)
            var bestSense: Int64? = nil
            var bestScore = 0
            var tiedAtBest = false

            for (senseID, tokens) in senseTokens {
                let score = sentenceTokens.intersection(tokens).count
                if score > bestScore {
                    bestScore = score
                    bestSense = senseID
                    tiedAtBest = false
                } else if score == bestScore && score > 0 {
                    tiedAtBest = true
                }
            }

            if let bestSense,
               bestScore >= 1,
               tiedAtBest == false,
               (bySense[bestSense]?.count ?? 0) < maxPerSense {
                bySense[bestSense, default: []].append(sentence)
            } else {
                unrouted.append(sentence)
            }
        }

        return Routing(bySense: bySense, unrouted: unrouted)
    }

    // Tokenizes English text into content words: lowercased, ≥3 characters, stop-words filtered.
    private static func meaningfulTokens(in text: String) -> Set<String> {
        var result = Set<String>()
        let lowered = text.lowercased()
        for raw in lowered.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let token = String(raw)
            guard token.count >= 3, stopWords.contains(token) == false else { continue }
            result.insert(token)
        }
        return result
    }

    // Common English function-words; anything below 3 chars is already filtered by length.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "had", "her", "was", "one",
        "our", "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see",
        "two", "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use", "any",
        "with", "this", "that", "have", "from", "they", "them", "were", "will", "your", "what",
        "when", "make", "like", "into", "than", "only", "some", "very", "just", "much", "been",
        "being", "would", "could", "should", "there", "their", "these", "those", "which", "while"
    ]
}
