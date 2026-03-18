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
}
