import Foundation

// Finds English in a note and proposes katakana for each run (Shiny make up → シャイニーメイクアップ).
// Each word is looked up as a dictionary loanword first; a candidate only counts if it sounds like
// the English (so "power" gets パワー, not the translation エネルギー), and a word with no such
// candidate is read as romaji when it isn't an English word and spells cleanly as romaji
// (Kioku → キオク), and spelled out by
// EnglishKatakanaTransliterator otherwise. Nothing is applied here — the Read
// tab shows the proposals for review.
nonisolated enum EnglishKatakanaConverter {
    // How close (0…1) a dictionary candidate's consonants must be to the spelled-out English.
    static let minimumSimilarity = 0.5

    // Runs of Latin words joined by single spaces or hyphens: "Shiny make up", "McDonald's". Full-width
    // letters count too (lyrics often write ｈｅａｒｔ or Ｓｈｉｎｅ　ｙｏｕｒ　ｌｉｇｈｔ).
    private static let runPattern = try! NSRegularExpression(
        pattern: "[A-Za-zＡ-Ｚａ-ｚ][A-Za-zＡ-Ｚａ-ｚ'’＇]*(?:[ 　\\-－][A-Za-zＡ-Ｚａ-ｚ][A-Za-zＡ-Ｚａ-ｚ'’＇]*)*"
    )

    // Proposals for every English run in `text`, in text order. `lookup` returns the katakana
    // dictionary forms glossed with an English word or phrase; `isEnglish` says whether a word
    // appears in any English gloss at all, which keeps English words off the romaji path.
    static func proposals(in text: String, lookup: (String) -> [LoanwordCandidate], isEnglish: (String) -> Bool) -> [TextConversion] {
        let ns = text as NSString
        return runPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let original = ns.substring(with: match.range)
            guard let (katakana, source) = convert(run: original, lookup: lookup, isEnglish: isEnglish) else { return nil }
            return TextConversion(range: match.range, original: original, replacement: katakana, source: source)
        }
    }

    // Katakana for one run: the whole phrase as a dictionary loanword if there is one, otherwise
    // each word converted and joined. The source is `.rules` if any word needed the rules.
    static func convert(run: String, lookup: (String) -> [LoanwordCandidate], isEnglish: (String) -> Bool) -> (String, TextConversionSource)? {
        // Full-width letters and spaces fold to ASCII (ｈｅａｒｔ → heart) before anything is looked up.
        let ascii = run.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "’", with: "'")
        let words = ascii.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard words.isEmpty == false else { return nil }
        if words.count > 1, let phrase = dictionaryKatakana(for: words.joined(separator: " "), spelled: words.joined(), lookup: lookup) {
            return (phrase, .dictionary)
        }
        var out = ""
        var usedRules = false
        for word in words {
            if let found = dictionaryKatakana(for: word, spelled: word, lookup: lookup) {
                out += found
            } else if let singular = pluralStem(word), let found = dictionaryKatakana(for: singular, spelled: singular, lookup: lookup) {
                out += found + pluralSuffix(after: singular)
            } else if isEnglish(word.lowercased()) == false, let romaji = RomajiToKana.convert(word.uppercased()) {
                // Romanized Japanese (Kioku, chibiusa) reads back exactly.
                out += romaji.kana
            } else {
                out += EnglishKatakanaTransliterator.transliterate(word)
                usedRules = true
            }
        }
        return out.isEmpty ? nil : (out, usedRules ? .rules : .dictionary)
    }

    // The best dictionary loanword for `english` that sounds like `spelled`, or nil.
    private static func dictionaryKatakana(for english: String, spelled: String, lookup: (String) -> [LoanwordCandidate]) -> String? {
        let target = EnglishKatakanaTransliterator.transliterate(spelled)
        let scored = lookup(english.lowercased()).map { ($0, EnglishKatakanaTransliterator.similarity($0.kana, target)) }
            .filter { $0.1 >= minimumSimilarity }
        return scored.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.frequency < b.0.frequency }?.0.kana
    }

    // The katakana plural ending: ツ after t (cats), ス after other voiceless sounds, ズ otherwise.
    private static func pluralSuffix(after singular: String) -> String {
        guard let last = singular.lowercased().last else { return "ズ" }
        if last == "t" { return "ツ" }
        return "kpf".contains(last) ? "ス" : "ズ"
    }

    // "dreams" → "dream", "boxes" → "box"; nil when the word doesn't end in a plural s.
    private static func pluralStem(_ word: String) -> String? {
        let w = word.lowercased()
        guard w.count > 3, w.hasSuffix("s"), w.hasSuffix("ss") == false else { return nil }
        if w.hasSuffix("es"), ["x", "sh", "ch"].contains(where: { w.dropLast(2).hasSuffix($0) }) { return String(w.dropLast(2)) }
        return String(w.dropLast())
    }
}
