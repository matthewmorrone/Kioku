import SwiftUI

// Hosts temporary kunyomi preference heuristics used by read-mode furigana selection.
extension ReadView {
    // Detects single-kanji segments where kunyomi should be preferred for reader-friendly isolation defaults.
    func shouldPreferKunyomiForSingleKanji(surface: String, in sourceText: String, segmentRange: Range<String.Index>) -> Bool {
        let surfaceCharacters = Array(surface)
        let kanjiCharacterCount = surfaceCharacters.reduce(into: 0) { count, character in
            if ScriptClassifier.containsKanji(String(character)) {
                count += 1
            }
        }

        _ = sourceText
        _ = segmentRange
        return kanjiCharacterCount == 1
    }

    // Picks a kunyomi-leaning candidate for standalone single-kanji contexts.
    func preferredKunyomiCandidate(from candidates: [String]) -> String? {
        guard candidates.isEmpty == false else {
            return nil
        }

        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let lhsScore = kunyomiPreferenceScore(lhs.element)
            let rhsScore = kunyomiPreferenceScore(rhs.element)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            if lhs.element.count != rhs.element.count {
                return lhs.element.count > rhs.element.count
            }

            // Keeps earlier dictionary order as the final tie-break while this heuristic remains temporary.
            return lhs.offset < rhs.offset
        }

        return ordered.first?.element
    }

    // Provides deterministic kunyomi picks for high-frequency single-kanji ambiguities.
    func preferredStandaloneKunyomiOverride(for surface: String) -> String? {
        let overrides: [String: String] = [
            "月": "つき",
            "星": "ほし",
            "日": "ひ",
        ]
        return overrides[surface]
    }

    // Scores readings so standalone-kanji segments can prefer kunyomi-like options.
    func kunyomiPreferenceScore(_ reading: String) -> Int {
        let scalarValues = reading.unicodeScalars.map(\.value)
        let hasSmallKana = scalarValues.contains { value in
            value == 0x3083 || value == 0x3085 || value == 0x3087 || value == 0x30E3 || value == 0x30E5 || value == 0x30E7
        }
        let hasSokuon = scalarValues.contains(0x3063) || scalarValues.contains(0x30C3)

        var score = 0
        if hasSmallKana == false {
            score += 15
        }

        if hasSokuon == false {
            score += 10
        }

        if reading.count <= 3 {
            score += 10
        }

        if let terminal = reading.last {
            if terminal == "い" || terminal == "う" {
                score -= 12
            }

            if ["し", "ち", "つ", "く", "む", "る", "り", "さ", "せ", "そ", "な", "の", "ま", "み", "も", "き"].contains(terminal) {
                score += 8
            }
        }

        return score
    }
}