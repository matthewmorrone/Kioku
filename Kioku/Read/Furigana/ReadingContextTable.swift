import Foundation

// Which reading a kanji takes next to which word classes, counted from Tatoeba's training sentences,
// whose index marks the reading of every headword that has more than one (時(じ) after a number,
// 方(かた) after a verb). FuriganaResolver asks it to choose among a word's dictionary readings by
//   P(reading | kanji) · P(class before | kanji, reading) · P(class after | kanji, reading)
// with class names from TransitionClass, as the transition table uses them. A kanji the counts never
// saw keeps the dictionary's frequency order.
//
// The numbers live in reading-contexts.tsv beside this file, built by
// scripts/calibration/count_reading_contexts.py; never edit it by hand. Measured on its own with
// scripts/segmentation-eval/score_readings.py: held2k 91.09% → 94.50%, fresh5k 94.79% → 96.97%.
nonisolated final class ReadingContextTable: Sendable {
    // Pseudo-count for a class never seen next to a reading: fitted on train2k (0.05–2 all within
    // 0.4 points; 0.2 best), confirmed on held2k and fresh5k.
    static let classSmoothing = 0.2

    // Counts by kanji run, then by its hiragana reading.
    private let countsByKanji: [String: [String: ReadingContextCounts]]
    // How many distinct classes the counts name: the smoothing's denominator.
    private let classCount: Int

    // Parses the table: "kanji <tab> reading <tab> count <tab> classes before <tab> classes after".
    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var countsByKanji: [String: [String: ReadingContextCounts]] = [:]
        var classes = Set<String>()
        // Reads a "name=count name=count" list.
        func classCounts(_ field: Substring) -> [String: Int] {
            var counts: [String: Int] = [:]
            for pair in field.split(separator: " ") {
                guard let equals = pair.lastIndex(of: "="), let n = Int(pair[pair.index(after: equals)...]) else { continue }
                let name = String(pair[..<equals])
                counts[name] = n
                classes.insert(name)
            }
            return counts
        }
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let total = Int(fields[2]) else {
                AppLog.error(.segmentation, "reading-contexts.tsv: skipping malformed row \(row)")
                continue
            }
            countsByKanji[String(fields[0]), default: [:]][String(fields[1])] = ReadingContextCounts(
                total: total, previous: classCounts(fields[3]), next: classCounts(fields[4])
            )
        }
        self.countsByKanji = countsByKanji
        self.classCount = max(1, classes.count)
    }

    // The table shipped with the app: from the bundle on device, or from the source tree when the
    // code runs outside an app bundle (unit tests, the command-line eval harness).
    static let bundled: ReadingContextTable? = {
        let besideThisFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("reading-contexts.tsv")
        let candidates = [Bundle.main.url(forResource: "reading-contexts", withExtension: "tsv"), besideThisFile]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                return try ReadingContextTable(contentsOf: url)
            } catch {
                AppLog.error(.segmentation, "reading-contexts.tsv at \(url.path) unreadable: \(error)")
            }
        }
        AppLog.error(.segmentation, "reading-contexts.tsv not loaded; furigana keeps the frequency order")
        return nil
    }()

    // The likeliest of `candidates` (hiragana run readings, in the dictionary's frequency order) for
    // `kanji` between a word of class `previous` and one of class `next`; nil when the counts never
    // saw this kanji. Ties keep the earlier candidate, so the frequency order breaks them.
    func choose(kanji: String, candidates: [String], previous: String, next: String) -> String? {
        guard let seen = countsByKanji[kanji], candidates.isEmpty == false else { return nil }
        let total = seen.values.reduce(0) { $0 + $1.total }
        var best: (reading: String, score: Double)?
        for reading in candidates {
            let counts = seen[reading]
            let n = Double(counts?.total ?? 0)
            var score = log((n + 1) / Double(total + candidates.count))
            for (observed, name) in [(counts?.previous, previous), (counts?.next, next)] {
                score += log((Double(observed?[name] ?? 0) + Self.classSmoothing) / (n + Self.classSmoothing * Double(classCount)))
            }
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
