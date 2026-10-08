import Foundation

// Per-surface reading and frequency data, built once from the materialized surface_readings table.
nonisolated struct SurfaceReadingData: Sendable {
    // Readings ordered by frequency rank (best first), capped at 8.
    let readings: [String]
    // Frequency metadata keyed by reading. Only populated for readings with at least one frequency signal.
    let frequencyByReading: [String: FrequencyData]
}

// Reference-type wrapper so SwiftUI compares a single pointer instead of diffing 327k dictionary entries.
// The map is built once on a background thread and never mutated after assignment.
// @unchecked Sendable: deeply immutable (a single `let data` set at init, no mutators), so it is safe
// to share across threads — e.g. captured by the subtitle importer's detached furigana-precompute task.
nonisolated final class SurfaceReadingDataMap: Equatable, @unchecked Sendable {
    let data: [String: SurfaceReadingData]
    // How a kanji word reads right after の, taken from JMdict's own の-expressions (の様に のように
    // → 様 よう, の度に → 度 たび). See readingsAfterNo(in:).
    let readingAfterNo: [String: String]

    // Creates an empty map for initial state before resources are loaded.
    init() {
        data = [:]
        readingAfterNo = [:]
    }

    // Wraps a fully populated map produced by fetchSurfaceReadingData().
    init(_ data: [String: SurfaceReadingData]) {
        self.data = data
        readingAfterNo = Self.readingsAfterNo(in: data)
    }

    // For each dictionary spelling の + kanji + kana (の様に), the kanji's reading there: the
    // spelling's top reading without its の and kana ending (のように → よう). A kanji is kept only
    // when every such expression agrees and the reading is one the kanji has on its own (様 lists
    // よう), so a reading that is part of a longer word (余 あま, from の余り あまり) is left out.
    private static func readingsAfterNo(in data: [String: SurfaceReadingData]) -> [String: String] {
        var readings: [String: Set<String>] = [:]
        for (surface, entry) in data where surface.hasPrefix("の") {
            guard let reading = entry.readings.first, reading.hasPrefix("の") else { continue }
            let body = surface.dropFirst()
            let kanji = body.prefix { ScriptClassifier.containsKanji(String($0)) }
            let ending = body.dropFirst(kanji.count)
            guard kanji.isEmpty == false, ending.allSatisfy({ ScriptClassifier.isPureHiragana(String($0)) }) else { continue }
            let rest = reading.dropFirst()
            guard rest.hasSuffix(ending) else { continue }
            let kanjiReading = String(rest.dropLast(ending.count))
            guard kanjiReading.isEmpty == false else { continue }
            readings[String(kanji), default: []].insert(kanjiReading)
        }
        var agreed: [String: String] = [:]
        for (kanji, candidates) in readings where candidates.count == 1 {
            guard let reading = candidates.first, data[kanji]?.readings.contains(reading) == true else { continue }
            agreed[kanji] = reading
        }
        return agreed
    }

    // Identity-based equality so SwiftUI skips diffing the dictionary contents.
    static func == (lhs: SurfaceReadingDataMap, rhs: SurfaceReadingDataMap) -> Bool {
        lhs === rhs
    }

    // Looks a surface up as written, then in its modern spelling — old-form kanji (氣づく) read
    // the same as the form the table is keyed by (気づく), and the mapping keeps length and offsets.
    subscript(surface: String) -> SurfaceReadingData? {
        SpellingNormalizer.firstHit(for: surface) { data[$0] }
    }
}
