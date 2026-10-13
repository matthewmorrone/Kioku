import Foundation

// Which reading a kanji takes next to which word classes, counted from Tatoeba's indexed sentences,
// whose index marks the reading of every headword that has more than one (時(じ) after a number,
// 方(かた) after a verb). FuriganaResolver asks it to choose among a word's dictionary readings by
//   P(reading | kanji) · P(class before | kanji, reading) · P(class after | kanji, reading)
// with class names from TransitionClass, as the transition table uses them. A kanji the counts never
// saw keeps the dictionary's frequency order.
//
// The numbers live in reading-contexts.tsv beside this file, built by
// scripts/calibration/count_reading_contexts.py; never edit it by hand. Measured on its own with
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

    // The weight KWDLC's counts (kwdlc-reading-contexts.tsv) carry beside Tatoeba's.
    // EXPERIMENT: overridable by KIOKU_KWDLC_WEIGHT.
    static let kwdlcWeight = Double(ProcessInfo.processInfo.environment["KIOKU_KWDLC_WEIGHT"] ?? "") ?? 1.0

    // Counts by kanji run, then by its hiragana reading.
    private let countsByKanji: [String: [String: ReadingContextCounts]]
    // How many distinct classes the counts name: the smoothing's denominator.
    private let classCount: Int

    // Parses and adds up the tables, each row "kanji <tab> reading <tab> count <tab> classes before <tab>
    // classes after", scaling a table's counts by its weight.
    init(sources: [(url: URL, weight: Double)]) throws {
        var countsByKanji: [String: [String: ReadingContextCounts]] = [:]
        var classes = Set<String>()
        for source in sources {
            let text = try String(contentsOf: source.url, encoding: .utf8)
            // Adds a "name=count name=count" list to `counts`, scaled by the table's weight.
            func addClassCounts(_ field: Substring, to counts: inout [String: Double]) {
                for pair in field.split(separator: " ") {
                    guard let equals = pair.lastIndex(of: "="), let n = Double(pair[pair.index(after: equals)...]) else { continue }
                    let name = String(pair[..<equals])
                    counts[name, default: 0] += n * source.weight
                    classes.insert(name)
                }
            }
            for row in text.split(separator: "\n") {
                let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 5, let total = Double(fields[2]) else {
                    AppLog.error(.segmentation, "\(source.url.lastPathComponent): skipping malformed row \(row)")
                    continue
                }
                var counts = countsByKanji[String(fields[0]), default: [:]][String(fields[1])] ?? ReadingContextCounts()
                counts.total += total * source.weight
                addClassCounts(fields[3], to: &counts.previous)
                addClassCounts(fields[4], to: &counts.next)
                countsByKanji[String(fields[0]), default: [:]][String(fields[1])] = counts
            }
        }
        self.countsByKanji = countsByKanji
        self.classCount = max(1, classes.count)
    }

    // The tables shipped with the app: Tatoeba's (required) and KWDLC's (added when present), from the
    // bundle on device, or from the source tree when the code runs outside an app bundle (unit tests, the
    // command-line eval harness).
    static let bundled: ReadingContextTable? = {
        // The first copy of a table named `name`.tsv that exists.
        func url(_ name: String) -> URL? {
            let besideThisFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("\(name).tsv")
            let candidates = [Bundle.main.url(forResource: name, withExtension: "tsv"), besideThisFile]
            return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let tatoeba = url("reading-contexts") else {
            AppLog.error(.segmentation, "reading-contexts.tsv not found; furigana keeps the frequency order")
            return nil
        }
        var sources = [(url: tatoeba, weight: 1.0)]
        if let kwdlc = url("kwdlc-reading-contexts") {
            sources.append((kwdlc, kwdlcWeight))
        } else {
            AppLog.error(.segmentation, "kwdlc-reading-contexts.tsv not found; furigana counts Tatoeba alone")
        }
        do {
            return try ReadingContextTable(sources: sources)
        } catch {
            AppLog.error(.segmentation, "reading-context tables unreadable: \(error)")
            return nil
        }
    }()

    // The likeliest of `candidates` (hiragana run readings, in the dictionary's frequency order) for
    // `kanji` between a word of class `previous` and one of class `next`; nil when the counts never
    // saw this kanji. Ties keep the earlier candidate, so the frequency order breaks them.
    func choose(kanji: String, candidates: [String], previous: String, next: String, appleReading: String? = nil) -> String? {
        guard let seen = countsByKanji[kanji], candidates.isEmpty == false else { return nil }
        let total = seen.values.reduce(0) { $0 + $1.total }
        var best: (reading: String, score: Double)?
        for reading in candidates {
            let counts = seen[reading] ?? ReadingContextCounts()
            var score = log((counts.total + 1) / (total + Double(candidates.count)))
            for (observed, name) in [(counts.previous, previous), (counts.next, next)] {
                score += log(((observed[name] ?? 0) + Self.classSmoothing) / (counts.total + Self.classSmoothing * Double(classCount)))
            }
            if reading == appleReading { score += Self.appleVote }
            if let current = best, current.score >= score { continue }
            best = (reading, score)
        }
        return best?.reading
    }
}

// One reading's counts in ReadingContextTable, weighted and summed over its tables: how often it occurs,
// and the classes seen before and after it.
nonisolated struct ReadingContextCounts: Sendable {
    var total = 0.0
    var previous: [String: Double] = [:]
    var next: [String: Double] = [:]
}
