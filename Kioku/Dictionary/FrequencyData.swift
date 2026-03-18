import Foundation

// Frequency metadata for a dictionary surface form, derived from JPDB and wordfreq at DB generation time.
public struct FrequencyData {
    // JPDB rank for the best (kanji, kana) pair. Lower = more frequent. Nil if not in JPDB corpus.
    public let jpdbRank: Int?
    // Zipf score from wordfreq (0–7 scale; higher = more frequent). Nil if unscored.
    public let wordfreqZipf: Double?
}
