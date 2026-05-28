import Foundation

// Provides shared kana normalization helpers used by reading alignment and script-level matching.
enum KanaNormalizer {
    // Normalizes kana variants so furigana alignment treats equivalent spellings as interchangeable.
    static func normalizeForFuriganaAlignment(_ text: String) -> String {
        var normalized = text
        for (source, target) in KanaData.alignmentNormalizations {
            normalized = normalized.replacingOccurrences(of: source, with: target)
        }
        return normalized
    }

    // Converts full-width katakana to the corresponding hiragana, leaving every other scalar
    // (prolonged sound mark, punctuation, latin) untouched. Used to render KANJIDIC2 on'yomi —
    // which are stored in katakana — as furigana, where hiragana is the conventional script.
    static func katakanaToHiragana(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            // 0x30A1…0x30F6 (ァ…ヶ) map 1:1 onto hiragana 0x3041…0x3096 with a fixed 0x60 offset.
            if (0x30A1...0x30F6).contains(scalar.value),
               let converted = Unicode.Scalar(scalar.value - 0x60) {
                result.append(converted)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
