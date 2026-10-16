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
    // How many sightings of a reading count against a neighbour class never seen beside it. Uncapped,
    // a class missing from 15,714 sightings of わたし cost it more than one missing from 5 of わたくし,
    // so 私 before a verb with no particle between (lyrics drop them) read わたくし. Swept offline with
    // simulate_readings.py: 10–1000 cost train2k up to 0.6 points; 3000 leaves train2k, held2k and
    // fresh5k scores as they were (one ungraded fresh5k change: 私ども → わたし) and fixes the lyrics' 私.
    static let classEvidenceCap = 3000.0

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
        scores(kanji: kanji, candidates: candidates, previous: previous, next: next,
               appleReading: appleReading, addedCounts: addedCounts).flatMap { Self.best(of: $0) }
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

    // Each candidate's score in its parts, in candidate order, with the counts behind them: what
    // `choose` decides by, and what segcli's `readings` mode prints. Nil when no counts saw this kanji.
    func scores(
        kanji: String,
        candidates: [String],
        previous: String,
        next: String,
        appleReading: String? = nil,
        addedCounts: [String: Double] = [:]
    ) -> [ReadingScore]? {
        let seen = countsByKanji[kanji] ?? [:]
        guard seen.isEmpty == false || addedCounts.isEmpty == false, candidates.isEmpty == false else { return nil }
        let total = Double(seen.values.reduce(0) { $0 + $1.total }) + addedCounts.values.reduce(0, +)
        return candidates.map { reading in
            let counts = seen[reading]
            let n = Double(counts?.total ?? 0)
            let added = addedCounts[reading] ?? 0
            let previousSeen = counts?.previous[previous] ?? 0
            let nextSeen = counts?.next[next] ?? 0
            // How likely the neighbour's class is beside this reading, from at most classEvidenceCap
            // sightings.
            func classTerm(_ observed: Int) -> Double {
                let sightings = min(n, Self.classEvidenceCap)
                return log((min(Double(observed), sightings) + Self.classSmoothing) / (sightings + Self.classSmoothing * Double(classCount)))
            }
            return ReadingScore(
                reading: reading,
                count: Int(n),
                addedCount: added,
                kanjiTotal: total,
                candidateCount: candidates.count,
                classCount: classCount,
                previousSeen: previousSeen,
                nextSeen: nextSeen,
                prior: log((n + added + 1) / (total + Double(candidates.count))),
                previous: classTerm(previousSeen),
                next: classTerm(nextSeen),
                apple: reading == appleReading ? Self.appleVote : 0
            )
        }
    }
}

// One reading's counts in ReadingContextTable: how often it occurs, and the classes seen before and
// after it.
nonisolated struct ReadingContextCounts: Sendable {
    let total: Int
    let previous: [String: Int]
    let next: [String: Int]
}
