import Foundation

// Katakana written for effect versus unknown loanwords. Inside a longer katakana run, a piece the
// dictionary only knows in hiragana (ナカナイ as 泣かない, イラ as いら) is either Japanese written in
// katakana (ナカナイ|ヨ) or a coincidental match inside a loanword or name (カステ|イラ, ミン|ツ).
// The common words tell them apart: 泣く ranks 417, いら 297,395, みん 17,902.
extension Segmenter {
    // Whether some word the piece can be read as (its lemmas, or the piece itself in hiragana) is
    // common in its usual spelling (bestWordRankByKana within SegmenterScoring.katakanaPieceMaxWordRank).
    // True when no ranks are loaded (SegmenterScoring.checksKatakanaPieceReadings off, or no store),
    // so every piece is kept.
    func isCommonHiraganaReading(of surface: String, lemmas: Set<String>) -> Bool {
        guard bestWordRankByKana.isEmpty == false else { return true }
        let candidates = lemmas.union([KanaNormalizer.katakanaToHiragana(surface)])
        let bestRank = candidates
            .compactMap { bestWordRankByKana[$0] ?? bestWordRankByKana[KanaNormalizer.katakanaToHiragana($0)] }
            .min()
        guard let bestRank else { return false }
        return bestRank <= SegmenterScoring.katakanaPieceMaxWordRank
    }
}
