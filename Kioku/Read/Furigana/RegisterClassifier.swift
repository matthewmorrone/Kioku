import Foundation

// Tells which kind of text a note is: everyday (Tatoeba's sentences), web (KWDLC's web pages) or
// literature (Aozora Bunko), by naive Bayes over character unigrams and bigrams counted from each
// (Resources/generate_db.py, import_reading_registers). Furigana uses it to decide which reading counts
// to add to Tatoeba's (ReadingRegisters). No model and no network: a table lookup per character.
nonisolated final class RegisterClassifier: Sendable {
    // The register names, in the order of each gram's counts.
    let registers: [String]
    private let counts: [String: [Int]]
    // log(total + vocabulary) per register: the smoothed denominator of every gram's probability.
    private let logDenominators: [Double]

    // Takes the counts as the dictionary stores them.
    init(counts: RegisterGramCounts) {
        registers = counts.registers
        self.counts = counts.counts
        logDenominators = counts.totals.map { log(Double($0 + counts.vocabulary)) }
    }

    // The register whose text `text` most resembles: the largest sum of log P(gram | register), with
    // add-one smoothing, over the text's grams with ^ and $ marking its ends. Unicode scalars, as the
    // generator counts them. Ties and empty text go to the first register.
    func register(of text: String) -> String? {
        guard registers.isEmpty == false else { return nil }
        let scalars = ["^"] + text.unicodeScalars.map { String($0) } + ["$"]
        var scores = [Double](repeating: 0, count: registers.count)
        // Adds one gram's log probability under each register.
        func add(_ gram: String) {
            let seen = counts[gram]
            for index in scores.indices {
                scores[index] += log(Double((seen?[index] ?? 0) + 1)) - logDenominators[index]
            }
        }
        for index in scalars.indices {
            add(scalars[index])
            if index + 1 < scalars.count { add(scalars[index] + scalars[index + 1]) }
        }
        var best = 0
        for index in scores.indices where scores[index] > scores[best] { best = index }
        return registers[best]
    }
}

// The classifier's counts as the dictionary stores them (register_grams, register_totals).
nonisolated struct RegisterGramCounts: Sendable {
    let registers: [String]
    let counts: [String: [Int]]
    let totals: [Int]
    let vocabulary: Int
}
