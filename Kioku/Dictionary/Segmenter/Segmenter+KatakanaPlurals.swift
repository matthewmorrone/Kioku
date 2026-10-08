import Foundation

// English plurals written in katakana (スターズ, ドロップス, ミンツ). JMdict lists the singular loanword
// (スター, ドロップ, ミント), never the plural, so without this a plural is cut into the noun and a
// stray kana (スター|ズ) and looks up as nothing. A plural resolves to its singular as a lemma, the
// way an inflected verb resolves to its dictionary form, so segmentation and lookup agree.
extension Segmenter {
    // Kana that end an English plural in katakana, and what the singular ends in instead: ズ and ス
    // are dropped (stars, drops), ツ is the ts of mints and parts, so the singular ends in ト.
    private static let pluralEndings: [Character: String] = ["ズ": "", "ス": "", "ツ": "ト"]

    // The singular a katakana surface is the plural of: a katakana noun the dictionary has, when the
    // surface itself is not a dictionary word. Nil otherwise, so real words ending in ス (バス, ボス,
    // ニュース) are never re-read.
    func katakanaPluralLemma(for surface: String) -> String? {
        guard surface.count >= 3, ScriptClassifier.isPureKatakana(surface), trie.contains(surface) == false,
              let last = surface.last, let replacement = Self.pluralEndings[last] else { return nil }
        let singular = String(surface.dropLast()) + replacement
        guard trie.contains(singular), PartOfSpeech.isNoun(trie.partOfSpeech(for: singular)) else { return nil }
        return singular
    }
}
