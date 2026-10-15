import Foundation

// Which reading a kanji takes next to which word classes, counted from Tatoeba's indexed sentences,
// whose index marks the reading of every headword that has more than one (時(じ) after a number,
// 方(かた) after a verb). FuriganaResolver asks it to choose among a word's dictionary readings by
//   P(reading | kanji) · P(class before | kanji, reading) · P(class after | kanji, reading)
// with class names from TransitionClass, as the transition table uses them. A kanji the counts never
// saw keeps the dictionary's frequency order.
//
// The numbers live in the dictionary's reading_contexts table, recounted at every dictionary build
// (Resources/generate_db.py, import_usage_tables). Measured on its own with
// scripts/segmentation-eval/score_readings.py: held2k 91.09% → 94.50%, fresh5k 94.79% → 96.97%
// (counts from the training half; the unused held-out sentences, added since, are worth +1 / +2 more).
nonisolated final class ReadingContextTable: Sendable {
    // Pseudo-count for a class never seen next to a reading: fitted on train2k (0.05–2 all within
    // 0.4 points; 0.2 best), confirmed on held2k and fresh5k.
    static let classSmoothing = 0.2
    // Log-odds added to the reading Apple's tokenizer gives (AppleTokenReadings): a vote that tips
    // close calls without overriding what the counts are sure of. Fitted on train2k (0: 94.17%,
    // 2: 94.57%, 4: 94.25%, 6: 93.85%), confirmed on held2k and fresh5k.
    static let appleVote = 2.0

    // Counts by kanji run, then by its hiragana reading.
    private let countsByKanji: [String: [String: ReadingContextCounts]]
    // How many distinct classes the counts name: the smoothing's denominator.
    private let classCount: Int

    // Builds the table from its rows, whose class lists read "name=count name=count".
    init(rows: [ReadingContextRow]) {
        var countsByKanji: [String: [String: ReadingContextCounts]] = [:]
        var classes = Set<String>()
        // Reads a "name=count name=count" list.
        func classCounts(_ field: String) -> [String: Int] {
            var counts: [String: Int] = [:]
            for pair in field.split(separator: " ") {
                guard let equals = pair.lastIndex(of: "="), let n = Int(pair[pair.index(after: equals)...]) else {
                    AppLog.error(.segmentation, "reading_contexts: skipping malformed class count \(pair)")
                    continue
                }
                let name = String(pair[..<equals])
                counts[name] = n
                classes.insert(name)
            }
            return counts
        }
        for row in rows {
            countsByKanji[row.kanji, default: [:]][row.reading] = ReadingContextCounts(
                total: row.count, previous: classCounts(row.previous), next: classCounts(row.next)
            )
        }
        self.countsByKanji = countsByKanji
        self.classCount = max(1, classes.count)
    }

    // The dictionary's table; nil when the dictionary has none or it can't be read, and furigana
    // then keeps the dictionary's frequency order.
    static func load(from store: DictionaryStore) -> ReadingContextTable? {
        do {
            let rows = try store.fetchReadingContexts()
            guard rows.isEmpty == false else {
                AppLog.error(.segmentation, "Dictionary has no reading_contexts; furigana keeps the frequency order")
                return nil
            }
            return ReadingContextTable(rows: rows)
        } catch {
            AppLog.error(.segmentation, "reading_contexts failed to load: \(error)")
            return nil
        }
    }

    // The likeliest of `candidates` (hiragana run readings, in the dictionary's frequency order) for
    // `kanji` between a word of class `previous` and one of class `next`; nil when no counts saw this
    // kanji. `addedCounts` (ReadingRegisters: a web note's web counts) join Tatoeba's in
    // P(reading | kanji); the class terms stay Tatoeba's, the only counts with classes. Ties keep the
    // earlier candidate, so the frequency order breaks them.
    func choose(
        kanji: String,
        candidates: [String],
        previous: String,
        next: String,
        appleReading: String? = nil,
        addedCounts: [String: Double] = [:]
    ) -> String? {
        let seen = countsByKanji[kanji] ?? [:]
        guard seen.isEmpty == false || addedCounts.isEmpty == false, candidates.isEmpty == false else { return nil }
        let total = Double(seen.values.reduce(0) { $0 + $1.total }) + addedCounts.values.reduce(0, +)
        var best: (reading: String, score: Double)?
        for reading in candidates {
            let counts = seen[reading]
            let n = Double(counts?.total ?? 0)
            var score = log((n + (addedCounts[reading] ?? 0) + 1) / (total + Double(candidates.count)))
            for (observed, name) in [(counts?.previous, previous), (counts?.next, next)] {
                score += log((Double(observed?[name] ?? 0) + Self.classSmoothing) / (n + Self.classSmoothing * Double(classCount)))
            }
            // Apple's vote only backs a reading the counts have seen: where they saw this kanji and
            // never in Apple's reading (瞬 only as またた), Apple's word is a different one (瞬き まばたき).
            if reading == appleReading, counts != nil || seen.isEmpty { score += Self.appleVote }
            if let current = best, current.score >= score { continue }
            best = (reading, score)
        }
        return best?.reading
    }
}

// One reading's counts in ReadingContextTable: how often it occurs, and the classes seen before and
// after it.
nonisolated struct ReadingContextCounts: Sendable {
    let total: Int
    let previous: [String: Int]
    let next: [String: Int]
}
