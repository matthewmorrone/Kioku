import Foundation

// Converts Japanese kana readings into a mora sequence with a romanized (phonemic) form — the
// text-side input a phoneme/romaji forced aligner needs (e.g. MMS + uroman: text → romanized tokens
// → align to acoustic posteriors). Pure and deterministic: Japanese is near-phonetic from kana, so
// this is a table + combining rules, not a grapheme→phoneme model. It operates on KANA (Kioku
// already resolves readings/furigana for every line), so no G2P model is needed on the Japanese side.
//
// Romaji is (modified) Hepburn — close enough to phonemic for alignment, and what uroman emits for
// Japanese. A later switch to a true IPA phoneme inventory is a small romaji→IPA remap on top of this.
//
// Coverage: gojūon + dakuten/handakuten, yōon (きゃ/しゃ/ちゃ/じゃ …), sokuon っ (consonant
// gemination, incl. っち→tch), long vowel ー, moraic ん, and small-vowel combos (ファ/ティ/ウィ …).
// Katakana is folded to hiragana first, so loanword-heavy lyrics (ムーンフラグメント) romanize too.
nonisolated enum MoraPhonemizer {
    // One mora: the source kana grapheme(s) it came from, plus its romanization.
    struct Mora: Equatable {
        let kana: String
        let romaji: String
    }

    // Segments `kana` into morae with romanized forms. Non-kana characters (stray latin, punctuation)
    // are emitted as single passthrough morae so callers can decide how to treat them.
    static func morae(fromKana kana: String) -> [Mora] {
        let chars = Array(foldKatakana(kana))
        var out: [Mora] = []
        var i = 0
        var pendingSokuon = false

        while i < chars.count {
            let c = chars[i]

            // Sokuon: geminate the NEXT mora's leading consonant. Defer until we know that mora.
            if c == "っ" {
                pendingSokuon = true
                i += 1
                continue
            }

            // Long-vowel mark: repeat the previous mora's final vowel.
            if c == "ー" {
                if let prev = out.last, let v = prev.romaji.last, "aeiou".contains(v) {
                    out.append(Mora(kana: "ー", romaji: String(v)))
                } else {
                    out.append(Mora(kana: "ー", romaji: "-"))
                }
                i += 1
                continue
            }

            // Base kana + optional following small kana (yōon glide or small vowel).
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            var consumed = 1
            var kanaStr = String(c)
            var romaji: String

            if let baseRomaji = Self.base[c] {
                if let n = next, Self.smallYGlide[n] != nil {
                    romaji = Self.applyYoon(base: c, baseRomaji: baseRomaji, small: n)
                    kanaStr.append(n)
                    consumed = 2
                } else if let n = next, let smallV = Self.smallVowel[n], baseRomaji.count >= 2 {
                    // Small-vowel combo: drop the base's vowel, append the small vowel (ふ+ぁ→fa).
                    romaji = String(baseRomaji.dropLast()) + smallV
                    kanaStr.append(n)
                    consumed = 2
                } else {
                    romaji = baseRomaji
                }
            } else {
                // Not kana we know (latin, digits, punctuation): pass through, no gemination.
                out.append(Mora(kana: String(c), romaji: String(c)))
                pendingSokuon = false
                i += 1
                continue
            }

            if pendingSokuon {
                romaji = Self.geminate(romaji)
                pendingSokuon = false
            }

            out.append(Mora(kana: kanaStr, romaji: romaji))
            i += consumed
        }

        // A trailing っ with nothing after it: emit a bare glottal marker so it isn't silently lost.
        if pendingSokuon { out.append(Mora(kana: "っ", romaji: "'")) }
        return out
    }

    // Convenience: the full romanization of a kana reading.
    static func romaji(fromKana kana: String) -> String {
        morae(fromKana: kana).map(\.romaji).joined()
    }

    // Prepends the geminating consonant for a sokuon before `romaji`. Hepburn uses "tch" for ち-row
    // (っち→tch), otherwise the doubled leading consonant; before a vowel/n there's nothing to double.
    private static func geminate(_ romaji: String) -> String {
        guard let first = romaji.first else { return romaji }
        if romaji.hasPrefix("ch") { return "t" + romaji }
        if "aeiou".contains(first) { return romaji }   // vowel-initial mora: no consonant to geminate
        return String(first) + romaji
    }

    // Builds a yōon (palatalized) mora. Sibilants し/ち/じ/ぢ take the bare vowel (sha/cha/ja);
    // everything else keeps the y-glide (kya/nya/rya …).
    private static func applyYoon(base: Character, baseRomaji: String, small: Character) -> String {
        let stem = String(baseRomaji.dropLast())   // drop the 'i': き"ki"→"k", し"shi"→"sh"
        let glide = Self.smallYGlide[small] ?? ("y", "")
        let sibilant: Set<Character> = ["し", "ち", "じ", "ぢ"]
        return sibilant.contains(base) ? stem + glide.bare : stem + glide.y
    }

    // Katakana → hiragana (scalar offset 0x60), leaving ー and anything else untouched, so one table
    // serves both scripts.
    private static func foldKatakana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value)
                ? (Unicode.Scalar(scalar.value - 0x60) ?? scalar)
                : scalar
        }))
    }

    // Small ゃ/ゅ/ょ → (y-glide form, sibilant bare-vowel form).
    private static let smallYGlide: [Character: (y: String, bare: String)] = [
        "ゃ": ("ya", "a"), "ゅ": ("yu", "u"), "ょ": ("yo", "o"),
    ]

    // Small vowels for loanword combos (ファ/ウィ/…).
    private static let smallVowel: [Character: String] = [
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
    ]

    // Base kana → Hepburn romaji.
    private static let base: [Character: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "wi", "ゑ": "we", "を": "o", "ん": "n",
        "ゔ": "vu",
    ]
}
