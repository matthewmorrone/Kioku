import Foundation

// Reading counts for kinds of text Tatoeba's everyday sentences don't cover, and which of them a note
// gets. Web writing reads 方 かた, その後 ご, 等 とう; literature has its own habits. The classifier
// (RegisterClassifier) names a note's register once; a web or literary note then adds that register's
// counts, scaled by its weight, to Tatoeba's reading counts (ReadingContextTable.choose). An everyday
// note gets Tatoeba's alone, exactly as before. Built from the dictionary's register tables
// (Resources/reading_registers.py); nil for a dictionary without them.
nonisolated final class ReadingRegisters: Sendable {
    // How much a register's counts weigh beside Tatoeba's. Fitted on held-out data only (KWDLC's dev
    // documents, Aozora's held-out works, Tatoeba's train2k): the largest weight that left train2k level.
    // Web 0.5–8: KWDLC dev +1.2 → +1.6 points, train2k −2 at 8; literature 0.5–32: Aozora dev +3.7 →
    // +5.5, flat from 8. Weights above 1 make up for the class terms, which stay Tatoeba's.
    static let weights: [String: Double] = ["web": 4, "literature": 8]

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
