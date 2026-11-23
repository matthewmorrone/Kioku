import Foundation

// Which reading a kanji run takes from the words around it. For every kanji run Tatoeba reads more than
// one way (時 after a number → じ, 方 after a verb → かた, 人気 in a sentence about empty streets →
// ひとけ) the dictionary carries one logistic regression: per reading a weight vector and a bias over
// ReadingContext's features, the embeddings of the word before, the word after, and the words within
// five places. FuriganaResolver asks it to choose among a word's dictionary readings by
//   log softmax over the candidates of ( bias + weights · features )
// A kanji with no model, and one the counts never saw, falls back to the reading frequencies alone
// (P(reading | kanji)), and one never counted keeps the dictionary's frequency order.
//
// The numbers live in the dictionary's reading_contexts and word_vectors tables, fitted at every
// dictionary build (Resources/generate_db.py, import_usage_tables; scripts/calibration/reading_model.py).
// Cross-validated offline against the class-and-neighbour-word counts it replaced: +0.5 points overall,
// +0.6 on kanji whose readings differ in meaning.
nonisolated final class ReadingContextTable: Sendable {
    // Log-odds added to the reading Apple's tokenizer gives (AppleTokenReadings): a vote that tips
    // close calls without overriding what the model is sure of.
    static let appleVote = 2.0
    // Log-odds added to a reading that makes the text around the run spell a dictionary expression
    // (PhraseReadingEvidence): 態をみろ read ざま spells ざまをみろ.
    static let phraseVote = 2.0

    // The word vectors the features are built from.
    let vectors: WordVectorTable
    // Per kanji run, its readings' counts and models.
    private let readingsByKanji: [String: [String: ReadingModelEntry]]

    // Builds the table from its rows; a weights blob of the wrong length is skipped and logged.
    init(rows: [ReadingContextRow], vectors: WordVectorTable) {
        var readingsByKanji: [String: [String: ReadingModelEntry]] = [:]
        for row in rows {
            var weights: [Float]?
            if let blob = row.weights {
                if blob.count == ReadingContext.featureCount * MemoryLayout<Float>.size {
                    weights = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                } else {
                    AppLog.error(.segmentation, "reading_contexts: skipping weights of \(row.kanji) \(row.reading), \(blob.count) bytes")
                }
            }
            readingsByKanji[row.kanji, default: [:]][row.reading] = ReadingModelEntry(count: row.count, bias: row.bias, weights: weights)
        }
        self.readingsByKanji = readingsByKanji
        self.vectors = vectors
    }

    // The dictionary's tables; nil when it has none or they can't be read, and furigana then keeps the
    // dictionary's frequency order.
    static func load(from store: DictionaryStore) -> ReadingContextTable? {
        do {
            let rows = try store.fetchReadingContexts()
            guard rows.isEmpty == false else {
                AppLog.error(.segmentation, "Dictionary has no reading_contexts; furigana keeps the frequency order")
                return nil
            }
            guard let vectors = WordVectorTable.load(from: store) else { return nil }
            return ReadingContextTable(rows: rows, vectors: vectors)
        } catch {
            AppLog.error(.segmentation, "reading_contexts failed to load: \(error)")
            return nil
        }
    }

    // The reading with the highest total; the earlier one on a tie, so the frequency order breaks it.
    static func best(of scores: [ReadingScore]) -> String? {
        var best: ReadingScore?
        for score in scores {
            if let current = best, current.total >= score.total { continue }
            best = score
        }
        return best?.reading
    }

    // Each candidate's score in its parts, in candidate order, with the counts behind them: what furigana
    // decides by, and what segcli's `readings` mode prints. Nil when no counts saw this kanji.
    // `candidates` are hiragana run readings in the dictionary's frequency order; `context` the features
    // around the run; `phraseReadings` the candidates that spell a dictionary expression with the text
    // around them. `addedCounts` (ReadingRegisters: a web note's web counts) join Tatoeba's in
    // P(reading | kanji), which for a kanji with a model shifts every reading by what they add to its prior.
    func scores(
        kanji: String,
        candidates: [String],
        context: ReadingContext,
        appleReading: String? = nil,
        phraseReadings: Set<String> = [],
        addedCounts: [String: Double] = [:]
    ) -> [ReadingScore]? {
        let seen = readingsByKanji[kanji] ?? [:]
        guard seen.isEmpty == false || addedCounts.isEmpty == false, candidates.isEmpty == false else { return nil }
        let total = Double(seen.values.reduce(0) { $0 + $1.count }) + addedCounts.values.reduce(0, +)
        let added = addedCounts.values.reduce(0, +)
        let candidateCount = Double(candidates.count)
        // The model's logit for each candidate it has weights for.
        let logits: [String: Double] = candidates.reduce(into: [:]) { logits, reading in
            if let entry = seen[reading], let weights = entry.weights {
                logits[reading] = Double(entry.bias) + context.dot(weights)
            }
        }
        // The log of the sum of exp over the modelled candidates: the softmax's normaliser.
        let modelled = logits.values.max().map { peak in
            peak + log(logits.values.reduce(0) { $0 + exp($1 - peak) })
        }
        let floor = logits.values.min()
        return candidates.map { reading in
            let n = Double(seen[reading]?.count ?? 0)
            let extra = addedCounts[reading] ?? 0
            let countedPrior = log((n + extra + 1) / (total + candidateCount))
            var prior = countedPrior
            var contextTerm = 0.0
            if let normaliser = modelled, let floor {
                // A model decides this kanji: its log-probability replaces the prior, which the bias already
                // holds, except for what a web note's added counts shift it by. A candidate the model never
                // saw sits below its lowest-scoring reading by as much as a single sighting would.
                prior = added > 0 ? countedPrior - log((n + 1) / (total - added + candidateCount)) : 0
                contextTerm = (logits[reading] ?? floor + log(1 / (total - added + candidateCount))) - normaliser
            }
            return ReadingScore(
                reading: reading,
                count: Int(n),
                addedCount: extra,
                kanjiTotal: total,
                candidateCount: candidates.count,
                prior: prior,
                context: contextTerm,
                apple: reading == appleReading ? Self.appleVote : 0,
                phrase: phraseReadings.contains(reading) ? Self.phraseVote : 0
            )
        }
    }
}

// One reading's counts and model in ReadingContextTable: how often Tatoeba's counts saw it, and, for a
// kanji with a model, the bias and ReadingContext.featureCount weights of its logit.
nonisolated struct ReadingModelEntry: Sendable {
    let count: Int
    let bias: Float
    let weights: [Float]?
}
