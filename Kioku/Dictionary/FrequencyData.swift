import Foundation

// Frequency metadata for a dictionary surface form, derived from JPDB and wordfreq at DB generation time.
nonisolated public struct FrequencyData: Sendable {
    // JPDB rank for the best (kanji, kana) pair. Lower = more frequent. Nil if not in JPDB corpus.
    public let jpdbRank: Int?
    // Zipf score from wordfreq (0–7 scale; higher = more frequent). Nil if unscored.
    public let wordfreqZipf: Double?

    // Unified frequency score on a ~0–7 Zipf-equivalent scale (higher = more frequent).
    // Takes the max of (a) the Zipf-mapped JPDB rank and (b) the raw wordfreq Zipf score
    // so a word labeled common by either source surfaces as common. Picking only one signal
    // mislabels words like ここ, where JPDB only ranks the rare kanji form 此処 while wordfreq
    // captures the everyday kana spelling.
    public var normalizedScore: Double? {
        let jpdbScore: Double? = jpdbRank.map { max(0.0, 7.0 - log10(Double($0))) }
        switch (jpdbScore, wordfreqZipf) {
        case let (jp?, wf?): return max(jp, wf)
        case let (jp?, nil): return jp
        case let (nil, wf?): return wf
        case (nil, nil):     return nil
        }
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
