import Foundation

// Spells an English word the way Japanese loanwords usually render it in katakana, from spelling
// rules alone (shiny → シャイニー, trickster → トリックスター). English spelling is irregular, so
// this is the fallback for words the dictionary has no loanword for, and the yardstick the
// converter uses to tell a real loanword (パワー for "power") from a translation (エネルギー).
// Every result is shown for review before it touches a note.
nonisolated enum EnglishKatakanaTransliterator {
    // Katakana for one English word (letters and apostrophes; anything else is dropped).
    static func transliterate(_ word: String) -> String {
        syllabify(phonemes(Array(word.lowercased().filter { $0.isLetter && $0.isASCII })))
    }

    // Romaji for a katakana string, long marks spelled as doubled vowels — the common ground
    // `similarity` compares a dictionary candidate and a transliteration on.
    static func romanize(_ katakana: String) -> String {
        var out = ""
        let chars = Array(katakana)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if i + 1 < chars.count, let pair = kanaToRomaji[String([c, chars[i + 1]])] {
                out += pair; i += 2; continue
            }
            if c == "ー" {
                if let last = out.last, "aiueo".contains(last) { out.append(last) }
            } else if c == "ッ" {
                if i + 1 < chars.count, let next = kanaToRomaji[String(chars[i + 1])], let f = next.first { out.append(f) }
            } else if let r = kanaToRomaji[String(c)] {
                out += r
            }
            i += 1
        }
        return out
    }

    // 0…1 closeness of two katakana strings by edit distance over their consonant skeletons
    // (vowels vary too much between an English spelling and its loanword to count), with the
    // sounds Japanese merges (r/l, b/v, s/z/ts) folded together.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = skeleton(romanize(a)), y = skeleton(romanize(b))
        guard x.isEmpty == false || y.isEmpty == false else { return 1 }
        let d = editDistance(x, y)
        return 1 - Double(d) / Double(max(x.count, y.count))
    }

    // MARK: - Spelling → phonemes

    // Reads the spelling left to right, longest grapheme first, into Japanese-style phonemes:
    // consonants as romaji ("k", "sh", "ch"), vowels as "a"…"o" or long/diphthong forms ("aa",
    // "ai"), and "Q" for a doubled consonant heard as a glottal stop (ッ).
    private static func phonemes(_ w: [Character]) -> [String] {
        var out: [String] = []
        var i = 0
        let n = w.count
        let isVowel: (Int) -> Bool = { $0 >= 0 && $0 < n && "aeiou".contains(w[$0]) }
        let at: (Int) -> Character? = { $0 >= 0 && $0 < n ? w[$0] : nil }
        let rest: (Int) -> String = { String(w[min($0, n)...]) }
        // A single vowel followed by one consonant and then a vowel (or a final y / silent e)
        // opens its syllable and is said long: shiny, make, home.
        func isOpen(_ i: Int) -> Bool {
            guard let c = at(i + 1), "aeiouwy".contains(c) == false, c != "r" || at(i + 2) == "e" else { return false }
            if at(i + 2) == "e", i + 3 == n { return true }
            if at(i + 2) == "y", i + 3 == n { return true }
            return false
        }
        while i < n {
            let c = w[i]
            let r = rest(i)
            // Consonant clusters.
            if r.hasPrefix("tch") { if isVowel(i - 1) { out.append("Q") }; out.append("ch"); i += 3; continue }
            if r.hasPrefix("ch") { out.append("ch"); i += 2; continue }
            if r.hasPrefix("sh") { out.append("sh"); i += 2; continue }
            if r.hasPrefix("ph") { out.append("f"); i += 2; continue }
            if r.hasPrefix("th") { out.append("s"); i += 2; continue }
            if r.hasPrefix("wh") { out.append("w"); i += 2; continue }
            if r.hasPrefix("wr") { out.append("r"); i += 2; continue }
            if r.hasPrefix("kn"), i == 0 { out.append("n"); i += 2; continue }
            if r.hasPrefix("gh") { i += 2; continue }
            if r.hasPrefix("ck") { if isVowel(i - 1) { out.append("Q") }; out.append("k"); i += 2; continue }
            if r.hasPrefix("qu") { out.append("k"); out.append("w"); i += 2; continue }
            if r.hasPrefix("ng") { out.append("n"); out.append("g"); i += 2; continue }
            // Vowel digraphs and r-coloured vowels.
            if r.hasPrefix("igh") { out.append("ai"); i += 3; continue }
            if r.hasPrefix("our") { out.append("awaa"); i += 3; continue }
            if r.hasPrefix("ee") || r.hasPrefix("ea") { out.append("ii"); i += 2; continue }
            if r.hasPrefix("oo") { out.append("uu"); i += 2; continue }
            if r.hasPrefix("oa") { out.append("oo"); i += 2; continue }
            if r.hasPrefix("ou") || (r.hasPrefix("ow") && (i + 2 == n || isVowel(i + 2) == false)) { out.append("au"); i += 2; continue }
            if r.hasPrefix("ai") || r.hasPrefix("ay") || r.hasPrefix("ei") || r.hasPrefix("ey") { out.append("ei"); i += 2; continue }
            if r.hasPrefix("au") || r.hasPrefix("aw") { out.append("oo"); i += 2; continue }
            if r.hasPrefix("oi") || r.hasPrefix("oy") { out.append("oi"); i += 2; continue }
            if r.hasPrefix("ew") || r.hasPrefix("ue") { out.append("yuu"); i += 2; continue }
            if "aeiou".contains(c), at(i + 1) == "r", isVowel(i + 2) == false, at(i + 2) != "r" {
                // ar → aa; or → oo (aa when it closes a longer word: sailor, doctor); er/ir/ur → aa.
                out.append(c == "o" && !(i + 2 == n && i > 1) ? "oo" : "aa")
                i += 2; continue
            }
            switch c {
            case "a": out.append(isOpen(i) ? "ei" : "a")
            case "e":
                if i == n - 1, i > 0 { break }                    // silent final e
                out.append(isOpen(i) ? "ii" : "e")
            case "i": out.append(isOpen(i) ? "ai" : "i")
            case "o": out.append(isOpen(i) ? "oo" : "o")
            case "u": out.append(isOpen(i) ? "yuu" : "a")
            case "y":
                if i == 0 || isVowel(i + 1) { out.append("y") } else { out.append(i == n - 1 ? "ii" : "i") }
            case "c": out.append(at(i + 1).map { "eiy".contains($0) } == true ? "s" : "k")
            case "g":
                out.append(at(i + 1) == "e" && i + 2 == n ? "j" : (at(i + 1).map { "iy".contains($0) } == true && i > 0 ? "j" : "g"))
            case "x": out.append("k"); out.append("s")
            case "j": out.append("j")
            case "l", "r": out.append("r")
            case "v": out.append("b")
            case "q": out.append("k")
            default:
                // Doubled consonants read as one; a final stop after a short vowel gets ッ (cup, hot).
                if i + 1 < n, w[i + 1] == c { i += 1 }
                if "ptk".contains(c), i == n - 1, isVowel(i - 1), (i < 2 || isVowel(i - 2) == false) { out.append("Q") }
                out.append(String(c))
            }
            i += 1
        }
        return out
    }

    // MARK: - Phonemes → katakana

    // Pairs each consonant with the vowel after it; a consonant with no vowel gets the epenthetic
    // vowel Japanese adds (o after t/d, i after ch/j, u otherwise), n alone becomes ン, and long
    // vowels take ー.
    private static func syllabify(_ p: [String]) -> String {
        var out = ""
        var i = 0
        while i < p.count {
            let s = p[i]
            if s == "Q" { out += "ッ"; i += 1; continue }
            if let v = vowelKana[s] { out += v; i += 1; continue }
            let next = i + 1 < p.count ? p[i + 1] : nil
            if let next, let first = next.first, "aiueo".contains(first) {
                let head = String(first)
                let tail = String(next.dropFirst())
                out += kana(consonant: s, vowel: head)
                if tail == head { out += "ー" } else if let t = vowelKana[tail] { out += t }
                i += 2; continue
            }
            if next?.hasPrefix("y") == true, let yv = next, yv.count > 1 {
                // y-glide vowel (yuu) after a consonant: new → ニュー.
                out += kana(consonant: s, vowel: "i") + yRow(yv)
                i += 2; continue
            }
            if s == "n" { out += "ン"; i += 1; continue }
            let epenthetic = (s == "t" || s == "d") ? "o" : (s == "ch" || s == "j") ? "i" : "u"
            out += kana(consonant: s, vowel: epenthetic)
            i += 1
        }
        return out
    }

    // A consonant + vowel mora, using the loanword spellings (ティ, ディ, トゥ, ファ, ウィ, シェ).
    private static func kana(consonant c: String, vowel v: String) -> String {
        let row: [String: [String]] = [
            "k": ["カ", "キ", "ク", "ケ", "コ"], "g": ["ガ", "ギ", "グ", "ゲ", "ゴ"],
            "s": ["サ", "シ", "ス", "セ", "ソ"], "z": ["ザ", "ジ", "ズ", "ゼ", "ゾ"],
            "t": ["タ", "ティ", "トゥ", "テ", "ト"], "d": ["ダ", "ディ", "ドゥ", "デ", "ド"],
            "n": ["ナ", "ニ", "ヌ", "ネ", "ノ"], "h": ["ハ", "ヒ", "フ", "ヘ", "ホ"],
            "b": ["バ", "ビ", "ブ", "ベ", "ボ"], "p": ["パ", "ピ", "プ", "ペ", "ポ"],
            "m": ["マ", "ミ", "ム", "メ", "モ"], "r": ["ラ", "リ", "ル", "レ", "ロ"],
            "y": ["ヤ", "イ", "ユ", "イェ", "ヨ"], "w": ["ワ", "ウィ", "ウ", "ウェ", "ウォ"],
            "f": ["ファ", "フィ", "フ", "フェ", "フォ"],
            "sh": ["シャ", "シ", "シュ", "シェ", "ショ"], "ch": ["チャ", "チ", "チュ", "チェ", "チョ"],
            "j": ["ジャ", "ジ", "ジュ", "ジェ", "ジョ"],
        ]
        guard let r = row[c], let idx = "aiueo".firstIndex(of: Character(v)) else { return vowelKana[v] ?? "" }
        return r["aiueo".distance(from: "aiueo".startIndex, to: idx)]
    }

    // The small-y kana (ュー etc.) that follows an i-row mora for a y-glide vowel.
    private static func yRow(_ yv: String) -> String {
        let v = yv.dropFirst()
        let base = v.first.map { ["a": "ャ", "u": "ュ", "o": "ョ"][String($0)] ?? "ュ" } ?? "ュ"
        return base + (v.count > 1 ? "ー" : "")
    }

    private static let vowelKana: [String: String] = [
        "a": "ア", "i": "イ", "u": "ウ", "e": "エ", "o": "オ",
        "aa": "アー", "ii": "イー", "uu": "ウー", "ee": "エー", "oo": "オー",
        "ai": "アイ", "ei": "エイ", "au": "アウ", "oi": "オイ", "yuu": "ユー", "awaa": "アワー",
    ]

    // MARK: - Scoring helpers

    // Consonants only, with r/l, b/v and s/z/ts/sh folded, so ハート ~ heart and パワー ~ power.
    private static func skeleton(_ romaji: String) -> [Character] {
        var s = romaji.replacingOccurrences(of: "tsu", with: "su")
            .replacingOccurrences(of: "sh", with: "s").replacingOccurrences(of: "ch", with: "c")
            .replacingOccurrences(of: "ts", with: "s")
        s = s.replacingOccurrences(of: "l", with: "r").replacingOccurrences(of: "v", with: "b")
            .replacingOccurrences(of: "z", with: "s").replacingOccurrences(of: "j", with: "c")
        return s.filter { "aiueoyw".contains($0) == false }.map { $0 }
    }

    // Levenshtein distance over characters.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private static let kanaToRomaji: [String: String] = {
        var m: [String: String] = [:]
        let rows: [(String, [String])] = [
            ("", ["ア", "イ", "ウ", "エ", "オ"]), ("k", ["カ", "キ", "ク", "ケ", "コ"]), ("g", ["ガ", "ギ", "グ", "ゲ", "ゴ"]),
            ("s", ["サ", "シ", "ス", "セ", "ソ"]), ("z", ["ザ", "ジ", "ズ", "ゼ", "ゾ"]), ("t", ["タ", "チ", "ツ", "テ", "ト"]),
            ("d", ["ダ", "ヂ", "ヅ", "デ", "ド"]), ("n", ["ナ", "ニ", "ヌ", "ネ", "ノ"]), ("h", ["ハ", "ヒ", "フ", "ヘ", "ホ"]),
            ("b", ["バ", "ビ", "ブ", "ベ", "ボ"]), ("p", ["パ", "ピ", "プ", "ペ", "ポ"]), ("m", ["マ", "ミ", "ム", "メ", "モ"]),
            ("r", ["ラ", "リ", "ル", "レ", "ロ"]), ("y", ["ヤ", "", "ユ", "", "ヨ"]), ("w", ["ワ", "ヰ", "", "ヱ", "ヲ"]),
            ("v", ["ヴァ", "ヴィ", "ヴ", "ヴェ", "ヴォ"]),
        ]
        for (c, kanas) in rows {
            for (k, v) in zip(kanas, ["a", "i", "u", "e", "o"]) where k.isEmpty == false { m[k] = c + v }
        }
        for (k, v) in ["シ": "shi", "チ": "chi", "ツ": "tsu", "フ": "fu", "ジ": "ji", "ン": "n", "ァ": "a", "ィ": "i", "ゥ": "u", "ェ": "e", "ォ": "o", "ャ": "ya", "ュ": "yu", "ョ": "yo"] { m[k] = v }
        for (k, v) in ["ティ": "ti", "ディ": "di", "トゥ": "tu", "ドゥ": "du", "ファ": "fa", "フィ": "fi", "フェ": "fe", "フォ": "fo",
                       "ウィ": "wi", "ウェ": "we", "ウォ": "wo", "シェ": "she", "チェ": "che", "ジェ": "je", "イェ": "ye",
                       "シャ": "sha", "シュ": "shu", "ショ": "sho", "チャ": "cha", "チュ": "chu", "チョ": "cho",
                       "ジャ": "ja", "ジュ": "ju", "ジョ": "jo", "ニュ": "nyu", "キュ": "kyu", "ミュ": "myu", "ピュ": "pyu", "ビュ": "byu", "ヒュ": "hyu", "リュ": "ryu", "ギャ": "gya", "キャ": "kya"] {
            m[k] = v
        }
        return m
    }()
}
