import Foundation

// Reading counts for kinds of text Tatoeba's everyday sentences don't cover, and which of them a note
// gets. Web writing reads 方 かた, その後 ご, 等 とう; literature has its own habits. The classifier
// (RegisterClassifier) names a note's register once; a web or literary note then adds that register's
// counts, scaled by its weight, to Tatoeba's reading counts (ReadingContextTable.choose). An everyday
// note gets Tatoeba's alone, exactly as before. Built from the dictionary's register tables
// (Resources/reading_registers.py); nil for a dictionary without them.
nonisolated final class ReadingRegisters: Sendable {
    // How much a register's counts weigh beside Tatoeba's. Fitted on held-out data: KWDLC's dev
    // documents, Aozora's held-out works and Tatoeba's train2k (scripts/segmentation-eval README).
    // EXPERIMENT: overridable by KIOKU_WEB_WEIGHT / KIOKU_LITERATURE_WEIGHT.
    static let weights: [String: Double] = [
        "web": Double(ProcessInfo.processInfo.environment["KIOKU_WEB_WEIGHT"] ?? "") ?? 0.75,
        "literature": Double(ProcessInfo.processInfo.environment["KIOKU_LITERATURE_WEIGHT"] ?? "") ?? 1.0,
    ]

    let classifier: RegisterClassifier
    // Register → kanji run → hiragana reading → count.
    private let counts: [String: [String: [String: Int]]]

    // Reads the tables; nil when the dictionary has none.
    init?(store: DictionaryStore) {
        do {
            guard let grams = try store.fetchRegisterGramCounts() else { return nil }
            classifier = RegisterClassifier(counts: grams)
            counts = try store.fetchReadingRegisterCounts()
        } catch {
            AppLog.error(.segmentation, "Reading register tables failed to load: \(error)")
            return nil
        }
    }

    // The weighted counts `register` adds for `kanji`'s readings; empty for everyday text and for a
    // kanji the register never counted.
    func addedCounts(kanji: String, register: String?) -> [String: Double] {
        guard let register, let weight = Self.weights[register], weight > 0,
              let readings = counts[register]?[kanji] else { return [:] }
        return readings.mapValues { Double($0) * weight }
    }
}
