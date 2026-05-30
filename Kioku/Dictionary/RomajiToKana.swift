import Foundation

// Wāpuro-style romaji → kana converter for the dictionary search field.
// Lowercase produces hiragana; uppercase produces katakana (with same-vowel long-vowel collapse to ー).
// Returns nil when input is empty, contains kana/kanji, or produces no conversions.
nonisolated enum RomajiToKana {
    struct Result: Equatable {
        let kana: String
        let didConvert: Bool
    }

    // Converts a wāpuro romaji string into kana, returning nil if nothing converts.
    static func convert(_ input: String) -> Result? {
        guard input.isEmpty == false else { return nil }
        if input.unicodeScalars.contains(where: isKanaOrKanji) { return nil }

        let chars = Array(input)
        var output = ""
        var index = 0
        var didConvert = false

        while index < chars.count {
            if let match = matchSyllable(chars, at: index) {
                output += match.kana
                index += match.consumed
                didConvert = true

                // Katakana same-vowel collapse: トウ → トー, キイ → キー, etc.
                if let vowel = trailingKatakanaVowel(of: match.kana),
                   index < chars.count,
                   isMatchingLongVowel(vowel: vowel, next: chars[index]) {
                    output.append("ー")
                    index += 1
                }
                continue
            }

            let current = chars[index]

            // Sokuon: doubled consonant followed by a valid syllable.
            if isSokuonCandidate(current),
               index + 1 < chars.count,
               chars[index + 1].lowercased() == current.lowercased(),
               matchSyllable(chars, at: index + 1) != nil {
                output.append(current.isUppercase ? "ッ" : "っ")
                index += 1
                didConvert = true
                continue
            }

            // `t` + `ch[aiueo]` → small つ + chi-row (matcha → まっちゃ).
            if current.lowercased() == "t",
               index + 1 < chars.count,
               chars[index + 1].lowercased() == "c",
               matchSyllable(chars, at: index + 1) != nil {
                output.append(current.isUppercase ? "ッ" : "っ")
                index += 1
                didConvert = true
                continue
            }

            // `n` cases: nn, n', n+consonant → ん. Trailing n left as ASCII.
            if current.lowercased() == "n", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "'" {
                    output.append(current.isUppercase ? "ン" : "ん")
                    index += 2
                    didConvert = true
                    continue
                }
                if next.lowercased() == "n" {
                    // nn + vowel/y → consume one n (second n begins the next syllable).
                    // nn at end or before any other consonant → consume both n's.
                    let following = index + 2 < chars.count ? chars[index + 2] : nil
                    let nextStartsNSyllable: Bool = {
                        guard let follow = following else { return false }
                        let lower = follow.lowercased()
                        return lower == "a" || lower == "i" || lower == "u" || lower == "e" || lower == "o" || lower == "y"
                    }()
                    output.append(current.isUppercase ? "ン" : "ん")
                    index += nextStartsNSyllable ? 1 : 2
                    didConvert = true
                    continue
                }
                if isConsonant(next), next.lowercased() != "y" {
                    output.append(current.isUppercase ? "ン" : "ん")
                    index += 1
                    didConvert = true
                    continue
                }
            }

            output.append(current)
            index += 1
        }

        guard didConvert else { return nil }
        // Reject mixed-script garbage like "Hello" → "ヘllお". Trailing ASCII letters
        // are kept (the "tan" → "たn" mid-typing case); embedded letters mean the
        // input wasn't really romaji.
        if hasEmbeddedAsciiLetter(output) { return nil }
        return Result(kana: output, didConvert: true)
    }

    // True when `s` contains any ASCII letter other than a single trailing n/N
    // (the deliberate "kon" → "こn" mid-typing case).
    private static func hasEmbeddedAsciiLetter(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        var endIndex = scalars.count
        if let last = scalars.last, last.value == 0x6E || last.value == 0x4E {
            endIndex -= 1
        }
        for i in 0..<endIndex where isAsciiLetter(scalars[i]) { return true }
        return false
    }

    // True for ASCII A–Z or a–z.
    private static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    // MARK: - Matching

    // Greedy longest-match for a romaji syllable starting at `start`; returns the kana plus characters consumed.
    private static func matchSyllable(_ chars: [Character], at start: Int) -> (kana: String, consumed: Int)? {
        for length in [3, 2, 1] {
            guard start + length <= chars.count else { continue }
            let slice = String(chars[start..<(start + length)])
            if let hiragana = syllableMap[slice.lowercased()] {
                let kana = chars[start].isUppercase ? hiraganaToKatakana(hiragana) : hiragana
                return (kana, length)
            }
        }
        return nil
    }

    // Shifts every hiragana scalar in the input by the +0x60 katakana offset.
    private static func hiraganaToKatakana(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x3041...0x3096).contains(v), let katakana = Unicode.Scalar(v + 0x60) {
                result.unicodeScalars.append(katakana)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Predicates

    // True for any scalar in the hiragana, katakana, or CJK ideograph blocks — signals "already Japanese".
    private static func isKanaOrKanji(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3040...0x309F).contains(v) ||  // Hiragana
               (0x30A0...0x30FF).contains(v) ||  // Katakana
               (0x31F0...0x31FF).contains(v) ||  // Katakana phonetic extensions
               (0x3400...0x4DBF).contains(v) ||  // CJK Extension A
               (0x4E00...0x9FFF).contains(v)     // CJK Unified Ideographs
    }

    // True for ASCII letters a–z excluding the five vowels.
    private static func isConsonant(_ c: Character) -> Bool {
        guard let first = c.lowercased().unicodeScalars.first else { return false }
        let v = first.value
        guard v >= 0x61, v <= 0x7A else { return false }   // ASCII a–z
        return v != 0x61 && v != 0x65 && v != 0x69 && v != 0x6F && v != 0x75 // not a/e/i/o/u
    }

    // A consonant that can act as the small-つ trigger when doubled — everything except `n` (which is ん).
    private static func isSokuonCandidate(_ c: Character) -> Bool {
        isConsonant(c) && c.lowercased() != "n"
    }

    // Decides whether the next character continues the previous syllable's vowel and should collapse to ー.
    private static func isMatchingLongVowel(vowel: Character, next: Character) -> Bool {
        let n = Character(next.lowercased())
        switch vowel {
        case "a": return n == "a"
        case "i": return n == "i"
        case "u": return n == "u"
        case "e": return n == "e"
        case "o": return n == "o" || n == "u"
        default: return false
        }
    }

    // Returns the romaji vowel of the kana's final scalar when that scalar is katakana; nil otherwise.
    private static func trailingKatakanaVowel(of kana: String) -> Character? {
        guard let lastScalar = kana.unicodeScalars.last,
              (0x30A0...0x30FF).contains(lastScalar.value) else { return nil }
        return katakanaVowelMap[Character(lastScalar)]
    }

    // MARK: - Tables

    // Wāpuro syllable table (all hiragana; katakana derived per call).
    private static let syllableMap: [String: String] = [
        // Yōon (3-letter)
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
        "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
        "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
        "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ",
        "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
        "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
        "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
        // 3-letter exceptional
        "shi": "し", "chi": "ち", "tsu": "つ", "dzu": "づ",

        // 2-letter
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と",
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "ya": "や", "yu": "ゆ", "yo": "よ",
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "wa": "わ", "wo": "を",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "ja": "じゃ", "ju": "じゅ", "jo": "じょ",

        // 1-letter vowels
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お"
    ]

    // Katakana → ending romaji vowel. Used only for the long-vowel collapse check.
    private static let katakanaVowelMap: [Character: Character] = [
        "ア": "a", "カ": "a", "サ": "a", "タ": "a", "ナ": "a", "ハ": "a", "マ": "a", "ヤ": "a", "ラ": "a", "ワ": "a",
        "ガ": "a", "ザ": "a", "ダ": "a", "バ": "a", "パ": "a", "ャ": "a", "ァ": "a",
        "イ": "i", "キ": "i", "シ": "i", "チ": "i", "ニ": "i", "ヒ": "i", "ミ": "i", "リ": "i",
        "ギ": "i", "ジ": "i", "ヂ": "i", "ビ": "i", "ピ": "i", "ィ": "i",
        "ウ": "u", "ク": "u", "ス": "u", "ツ": "u", "ヌ": "u", "フ": "u", "ム": "u", "ユ": "u", "ル": "u",
        "グ": "u", "ズ": "u", "ヅ": "u", "ブ": "u", "プ": "u", "ュ": "u", "ゥ": "u", "ヴ": "u",
        "エ": "e", "ケ": "e", "セ": "e", "テ": "e", "ネ": "e", "ヘ": "e", "メ": "e", "レ": "e",
        "ゲ": "e", "ゼ": "e", "デ": "e", "ベ": "e", "ペ": "e", "ェ": "e",
        "オ": "o", "コ": "o", "ソ": "o", "ト": "o", "ノ": "o", "ホ": "o", "モ": "o", "ヨ": "o", "ロ": "o", "ヲ": "o",
        "ゴ": "o", "ゾ": "o", "ド": "o", "ボ": "o", "ポ": "o", "ョ": "o", "ォ": "o"
    ]
}
