import Foundation

// Regular respellings of a katakana loanword: the sound correspondences by which older or looser
// spellings differ from the ones JMdict lists (ファ/ハ in ウエファース/ウエハース, テイ/ティ in
// スパゲテイ/スパゲティ, ヴァ/バ, ヰ/イ, small and full-size kana, long vowels written イ or ウ or
// left out). General rules over the script, not a list of words; DictionaryStore.katakanaSpellingGuess
// checks which variants the dictionary has.
nonisolated enum KatakanaSpellingVariants {
    // Each pair is rewritten in both directions.
    private static let correspondences: [(String, String)] = [
        ("ファ", "ハ"), ("フィ", "ヒ"), ("フェ", "ヘ"), ("フォ", "ホ"),
        ("ティ", "チ"), ("ティ", "テイ"), ("ディ", "デイ"), ("ディ", "ジ"), ("デュ", "ジュ"),
        ("ヴァ", "バ"), ("ヴィ", "ビ"), ("ヴ", "ブ"), ("ヴェ", "ベ"), ("ヴォ", "ボ"),
        ("ウィ", "ウイ"), ("ウェ", "ウエ"), ("ウォ", "ウオ"), ("イェ", "イエ"),
        ("ヂ", "ジ"), ("ヅ", "ズ"), ("ヰ", "イ"), ("ヱ", "エ"), ("ヲ", "オ"),
        ("ャ", "ヤ"), ("ュ", "ユ"), ("ョ", "ヨ"), ("ァ", "ア"), ("ィ", "イ"), ("ゥ", "ウ"),
        ("ェ", "エ"), ("ォ", "オ"), ("ッ", "ツ"),
        ("イ", "ー"), ("ウ", "ー"),
    ]

    // Every respelling of `word` within two rewrites, the one-rewrite variants first (each group in
    // a fixed order), without `word` itself.
    static func variants(of word: String) -> [(spelling: String, rewrites: Int)] {
        let first = oneRewrite(word)
        var second = Set<String>()
        for variant in first { second.formUnion(oneRewrite(variant)) }
        second.subtract(first)
        second.remove(word)
        return first.sorted().map { ($0, 1) } + second.sorted().map { ($0, 2) }
    }

    // The spellings one rewrite away: a correspondence swapped at one place, a ー or イ after the
    // first character dropped, or a ー added at the end.
    private static func oneRewrite(_ word: String) -> Set<String> {
        var variants = Set<String>()
        for (lhs, rhs) in correspondences {
            for (from, to) in [(lhs, rhs), (rhs, lhs)] {
                var searchStart = word.startIndex
                while let range = word.range(of: from, range: searchStart..<word.endIndex) {
                    variants.insert(word.replacingCharacters(in: range, with: to))
                    searchStart = word.index(after: range.lowerBound)
                }
            }
        }
        let characters = Array(word)
        for index in characters.indices.dropFirst() where characters[index] == "ー" || characters[index] == "イ" {
            var shortened = characters
            shortened.remove(at: index)
            variants.insert(String(shortened))
        }
        variants.insert(word + "ー")
        variants.remove(word)
        return variants
    }
}
