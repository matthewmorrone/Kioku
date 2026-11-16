import Foundation

// Which reading a kanji takes next to which words, counted from Tatoeba's indexed sentences, whose
// index marks the reading of every headword that has more than one (時(じ) after a number, 方(かた)
// after a verb). FuriganaResolver asks it to choose among a word's dictionary readings by
//   P(reading | kanji) · P(word before | kanji, reading) · P(word after | kanji, reading)
// where a neighbour is its class (TransitionClass, as the transition table names it), moved by how
// much more or less often the counts saw that very word beside this reading than its class predicts.
// A kanji the counts never saw keeps the dictionary's frequency order.
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
    // Log-odds added to a reading that makes the text around the run spell a dictionary expression
    // (PhraseReadingEvidence): 態をみろ read ざま spells ざまをみろ.
    static let phraseVote = 2.0
    // How many sightings of a reading count against a neighbour class never seen beside it. Uncapped,
    // a class missing from 15,714 sightings of わたし cost it more than one missing from 5 of わたくし,
    // so 私 before a verb with no particle between (lyrics drop them) read わたくし. Swept offline with
    // simulate_readings.py: 10–1000 cost train2k up to 0.6 points; 3000 leaves train2k, held2k and
    // fresh5k scores as they were (one ungraded fresh5k change: 私ども → わたし) and fixes the lyrics' 私.
    static let classEvidenceCap = 3000.0
    // Pseudo-sightings on each side of a neighbour word's observed-over-expected ratio (slotTerm).
    // Fitted on train2k with gold segmentation (0.5 and 1 best, 5 back to the class model).
    static let wordPseudoSightings = 1.0

    // Counts by kanji run, then by its hiragana reading.
    private let countsByKanji: [String: [String: ReadingContextCounts]]
    // How many distinct classes the counts name: the smoothing's denominator.
    private let classCount: Int

    // Builds the table from its rows, whose class lists read "name=count name=count" and word lists
    // "class<TAB>lemma=count".
    init(rows: [ReadingContextRow]) {
        var countsByKanji: [String: [String: ReadingContextCounts]] = [:]
        var classes = Set<String>()
        // Reads a "key=count key=count" list; the keys of class lists join the smoothing's classes.
        func counts(_ field: String, areClasses: Bool) -> [String: Int] {
            var counts: [String: Int] = [:]
            for pair in field.split(separator: " ") {
                guard let equals = pair.lastIndex(of: "="), let n = Int(pair[pair.index(after: equals)...]) else {
                    AppLog.error(.segmentation, "reading_contexts: skipping malformed count \(pair)")
                    continue
                }
                let name = String(pair[..<equals])
                counts[name] = n
                if areClasses { classes.insert(name) }
            }
            return counts
        }
        for row in rows {
            let slots = [
                ReadingSlotCounts(classes: counts(row.previous, areClasses: true), words: counts(row.previousWords, areClasses: false)),
                ReadingSlotCounts(classes: counts(row.next, areClasses: true), words: counts(row.nextWords, areClasses: false)),
            ]
            countsByKanji[row.kanji, default: [:]][row.reading] = ReadingContextCounts(total: row.count, slots: slots)
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
    // `candidates` are hiragana run readings in the dictionary's frequency order; `neighbours` the words
    // directly before and after the run (ReadingNeighbour), BOUNDARY past the text; `phraseReadings` the candidates that spell a dictionary expression with the text around
    // them. `addedCounts` (ReadingRegisters: a web note's web counts) join Tatoeba's in
    // P(reading | kanji); the neighbour terms stay Tatoeba's, the only counts with neighbours.
    func scores(
        kanji: String,
        candidates: [String],
        neighbours: [ReadingNeighbour],
        appleReading: String? = nil,
        phraseReadings: Set<String> = [],
        addedCounts: [String: Double] = [:]
    ) -> [ReadingScore]? {
        let seen = countsByKanji[kanji] ?? [:]
        guard seen.isEmpty == false || addedCounts.isEmpty == false, candidates.isEmpty == false,
              neighbours.count == 2 else { return nil }
        let total = Double(seen.values.reduce(0) { $0 + $1.total }) + addedCounts.values.reduce(0, +)
        // Per slot, how often this kanji's readings together saw the neighbour's word and its class:
        // a word never seen beside the kanji says nothing about the reading and keeps the class term.
        let kanjiWordSightings = (0..<2).map { slot in
            neighbours[slot].wordKey.map { key in seen.values.reduce(0) { $0 + ($1.slots[slot].words[key] ?? 0) } } ?? 0
        }
        let kanjiClassSightings = (0..<2).map { slot in
            seen.values.reduce(0) { $0 + ($1.slots[slot].classes[neighbours[slot].className] ?? 0) }
        }
        // One neighbour slot's log probability beside `reading`: the class term, moved by how far the
        // word's count beside this reading departs from what the class model expects of it, when the
        // word was seen beside this kanji at all. Pseudo-sightings on both sides keep a word seen twice
        // from outweighing thousands of sightings of a reading: smoothing the word's own probability
        // instead put にん on 人います (いる seen twice after にん, never in 2,781 ひと).
        func slotTerm(_ slot: Int, reading: String) -> Double {
            let counts = seen[reading]
            let n = Double(counts?.total ?? 0)
            let sightings = min(n, Self.classEvidenceCap)
            let observed = Double(counts?.slots[slot].classes[neighbours[slot].className] ?? 0)
            let classTerm = log((min(observed, sightings) + Self.classSmoothing) / (sightings + Self.classSmoothing * Double(classCount)))
            guard let key = neighbours[slot].wordKey, kanjiWordSightings[slot] > 0 else { return classTerm }
            // The word's share of its class beside this kanji: P(word | class), which the class term lacks.
            let share = Double(kanjiWordSightings[slot] + 1) / Double(kanjiClassSightings[slot] + 1)
            let wordSeen = Double(counts?.slots[slot].words[key] ?? 0)
            let expected = n * exp(classTerm) * share
            return classTerm + log((wordSeen + Self.wordPseudoSightings) / (expected + Self.wordPseudoSightings))
        }
        return candidates.map { reading in
            let counts = seen[reading]
            let n = Double(counts?.total ?? 0)
            let added = addedCounts[reading] ?? 0
            return ReadingScore(
                reading: reading,
                count: Int(n),
                addedCount: added,
                kanjiTotal: total,
                candidateCount: candidates.count,
                classCount: classCount,
                previousSeen: counts?.slots[0].classes[neighbours[0].className] ?? 0,
                nextSeen: counts?.slots[1].classes[neighbours[1].className] ?? 0,
                prior: log((n + added + 1) / (total + Double(candidates.count))),
                previous: slotTerm(0, reading: reading),
                next: slotTerm(1, reading: reading),
                apple: reading == appleReading ? Self.appleVote : 0,
                phrase: phraseReadings.contains(reading) ? Self.phraseVote : 0
            )
        }
    }
}

// One reading's counts in ReadingContextTable: how often it occurs, and per neighbour slot (before,
// after) the classes and words seen there.
nonisolated struct ReadingContextCounts: Sendable {
    let total: Int
    let slots: [ReadingSlotCounts]
}

// The classes, and the "class<TAB>lemma" words, seen in one neighbour slot of a reading.
nonisolated struct ReadingSlotCounts: Sendable {
    let classes: [String: Int]
    let words: [String: Int]
}
