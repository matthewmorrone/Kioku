import Foundation

// Frequency metadata for a dictionary surface form, derived from the frequency list (Jiten) and wordfreq at DB generation time.
nonisolated public struct FrequencyData: Sendable {
    // Frequency rank for the best (kanji, kana) pair. Lower = more frequent. Nil if unranked.
    public let frequencyRank: Int?
    // Zipf score from wordfreq (0–7 scale; higher = more frequent). Nil if unscored.
    public let wordfreqZipf: Double?

    // Unified frequency score on a ~0–7 Zipf-equivalent scale (higher = more frequent).
    // Takes the max of (a) the Zipf-mapped frequency rank and (b) the raw wordfreq Zipf score
    // so a word labeled common by either source surfaces as common. Picking only one signal
    // mislabels words like ここ, whose kanji-form rank (此処, 25682) is far rarer than the word, while wordfreq
    // captures the everyday kana spelling.
    public var normalizedScore: Double? {
        let rankScore: Double? = frequencyRank.map { max(0.0, 7.0 - log10(Double($0))) }
        switch (rankScore, wordfreqZipf) {
        case let (jp?, wf?): return max(jp, wf)
        case let (jp?, nil): return jp
        case let (nil, wf?): return wf
        case (nil, nil):     return nil
        }
    }

    // Human-readable frequency tier derived from the normalized score.
    //
    // Thresholds are calibrated against the ACTUAL score distribution across the dictionary
    // (~204k scored entries, after wordfreq_zipf is populated — see generate_db.py's import_wordfreq()),
    // not picked off intuition. The earlier 6/5/4/3 cutoffs put the median word (score ~3.7)
    // in "Rare" and labeled only ~6% of entries Common-or-better, so everyday words like
    // 日 (6.38) read "Uncommon". The bands below sit roughly at distribution breakpoints so
    // labels track learner intuition: 日/人/時間 → Very Common, 水/猫/食べる → Common,
    // 瞳/薔薇 → Uncommon, 引力/麒麟 → Rare. Resulting spread ≈ 2% / 13% / 44% / 27% / 14%.
    public var frequencyLabel: String? {
        guard let score = normalizedScore else { return nil }
        switch score {
        case 5.5...: return "Very Common"
        case 4.5...: return "Common"
        case 3.5...: return "Uncommon"
        case 2.5...: return "Rare"
        default:     return "Very Rare"
        }
    }
}
