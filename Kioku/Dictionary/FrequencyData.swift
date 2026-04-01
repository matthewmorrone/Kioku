import Foundation

// Frequency metadata for a dictionary surface form, derived from JPDB and wordfreq at DB generation time.
nonisolated public struct FrequencyData {
    // JPDB rank for the best (kanji, kana) pair. Lower = more frequent. Nil if not in JPDB corpus.
    public let jpdbRank: Int?
    // Zipf score from wordfreq (0–7 scale; higher = more frequent). Nil if unscored.
    public let wordfreqZipf: Double?

    // Unified frequency score on a ~0–7 Zipf-equivalent scale (higher = more frequent).
    // jpdbRank is preferred; wordfreqZipf used as fallback. Matches the formula used in path enumeration.
    public var normalizedScore: Double? {
        if let rank = jpdbRank {
            return max(0.0, 7.0 - log10(Double(rank)))
        }
        return wordfreqZipf
    }

    // Human-readable frequency tier derived from the normalized score.
    public var frequencyLabel: String? {
        guard let score = normalizedScore else { return nil }
        switch score {
        case 6.0...: return "Very Common"
        case 5.0...: return "Common"
        case 4.0...: return "Uncommon"
        case 3.0...: return "Rare"
        default:     return "Very Rare"
        }
    }
}
