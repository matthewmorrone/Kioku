// LyricRomanizer.swift
//
// Turns one lyric line into the romanized spans the forced aligner reads (see
// LyricAlignment.RomanizedSpan): kanji runs get their dictionary reading from the same
// furigana resolver the reader uses, kana is transliterated directly, and every span remembers
// the UTF-16 range of the line it came from so the aligner's times land back on the text.

import Foundation
import LyricAlignment

// Nonisolated and Sendable so the aligner can romanize a whole note off the main thread.
nonisolated struct LyricRomanizer: Sendable {
    let segmenter: any TextSegmenting
    let surfaceReadingData: SurfaceReadingDataMap
    let kanjiReadingFallback: KanjiReadingFallbackMap

    // One kana (or one kanji run) with its reading and source range.
    private struct Mora {
        let kana: String          // hiragana
        let offsetUTF16: Int
        let lengthUTF16: Int
    }

    // Romanizes one line into spans: kanji runs via their resolved reading, kana directly.
    func spans(for line: String) -> [RomanizedSpan] {
        let edges = segmenter.longestMatchEdges(for: line)
        let furigana = FuriganaResolver(segmenter: segmenter, kanjiReadingFallback: kanjiReadingFallback)
            .build(for: line, edges: edges, surfaceReadingData: surfaceReadingData)

        // Walk the line by UTF-16 offset, substituting readings over kanji runs.
        var morae: [Mora] = []
        let utf16 = Array(line.utf16)
        var offset = 0
        while offset < utf16.count {
            if let reading = furigana.byLocation[offset], let length = furigana.lengthByLocation[offset], length > 0 {
                morae.append(Mora(kana: KanaNormalizer.katakanaToHiragana(reading), offsetUTF16: offset, lengthUTF16: length))
                offset += length
                continue
            }
            // One Character (may be a surrogate pair) at this offset.
            let idx = String.Index(utf16Offset: offset, in: line)
            let ch = line[idx]
            let width = String(ch).utf16.count
            let hira = KanaNormalizer.katakanaToHiragana(String(ch))
            if Self.isKana(hira) {
                // Attach a following small ゃゅょ/ぁぃぅぇぉ to this mora.
                var length = width
                var kana = hira
                let nextOffset = offset + width
                if nextOffset < utf16.count {
                    let nextIdx = String.Index(utf16Offset: nextOffset, in: line)
                    let next = KanaNormalizer.katakanaToHiragana(String(line[nextIdx]))
                    if Self.smallKana.contains(next) {
                        kana += next
                        length += String(line[nextIdx]).utf16.count
                    }
                }
                morae.append(Mora(kana: kana, offsetUTF16: offset, lengthUTF16: length))
                offset += length
            } else if let run = Self.acronymLength(in: utf16, at: offset) {
                // Short all-caps runs (OK, DJ, TV) are sung as Japanese letter names, one span per
                // letter, so they get timings like any other word.
                for i in offset..<(offset + run) {
                    morae.append(Mora(kana: Self.letterNames[utf16[i]] ?? "", offsetUTF16: i, lengthUTF16: 1))
                }
                offset += run
            } else {
                offset += width   // punctuation, digits, other Latin text: no span
            }
        }

        // Where a segment that is the particle は or へ starts (UTF-16): sung "wa" and "e", not as
        // the kana spells them.
        var particleOffsets: [Int: String] = [:]
        for edge in edges {
            if let sung = Self.particleRomaji[edge.surface] {
                particleOffsets[edge.start.utf16Offset(in: line)] = sung
            }
        }

        // Romanize with the context っ and ー need from their neighbours.
        var romaji = morae.map { Self.romanize($0.kana) }
        for i in morae.indices {
            if let sung = particleOffsets[morae[i].offsetUTF16], morae[i].lengthUTF16 == 1 { romaji[i] = sung }
        }
        for i in romaji.indices {
            if morae[i].kana == "っ" {
                let next = i + 1 < romaji.count ? romaji[i + 1] : ""
                romaji[i] = next.first.map { Self.vowels.contains($0) ? "" : String($0) } ?? ""
            } else if morae[i].kana == "ー" {
                let prev = i > 0 ? romaji[i - 1] : ""
                romaji[i] = prev.last.map { Self.vowels.contains($0) ? String($0) : "" } ?? ""
            }
        }
        return zip(morae, romaji).compactMap { mora, r in
            r.isEmpty ? nil : RomanizedSpan(romaji: r, charOffsetUTF16: mora.offsetUTF16, charLengthUTF16: mora.lengthUTF16)
        }
    }

    // The particles は and へ as they are sung, keyed by a segment's whole surface; Sing mode's
    // planner reads the same table, so the aligner and the grader expect the same sounds.
    static let particleRomaji: [String: String] = ["は": "wa", "へ": "e"]

    private static let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
    private static let smallKana: Set<String> = ["ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]

    // Length of the all-caps ASCII run starting at `offset` when it is a whole acronym: 1–4
    // capitals with no Latin letter directly before or after (so "OK" and "DJ" qualify, while
    // "Baby" and "LOVELY" are words that shouldn't be spelled out). Nil otherwise.
    private static func acronymLength(in utf16: [UInt16], at offset: Int) -> Int? {
        guard isUpper(utf16[offset]), offset == 0 || isLatinLetter(utf16[offset - 1]) == false else { return nil }
        var end = offset
        while end < utf16.count, isUpper(utf16[end]) { end += 1 }
        let length = end - offset
        guard length <= 4, end == utf16.count || isLatinLetter(utf16[end]) == false else { return nil }
        return length
    }

    // True for an ASCII capital A–Z.
    private static func isUpper(_ u: UInt16) -> Bool { (0x41...0x5A).contains(u) }

    // True for an ASCII letter of either case — the neighbours that make a capital run a word.
    private static func isLatinLetter(_ u: UInt16) -> Bool { isUpper(u) || (0x61...0x7A).contains(u) }

    // How each capital letter is read aloud in Japanese, in hiragana.
    private static let letterNames: [UInt16: String] = [
        0x41: "えー", 0x42: "びー", 0x43: "しー", 0x44: "でぃー", 0x45: "いー", 0x46: "えふ",
        0x47: "じー", 0x48: "えいち", 0x49: "あい", 0x4A: "じぇー", 0x4B: "けー", 0x4C: "える",
        0x4D: "えむ", 0x4E: "えぬ", 0x4F: "おー", 0x50: "ぴー", 0x51: "きゅー", 0x52: "あーる",
        0x53: "えす", 0x54: "てぃー", 0x55: "ゆー", 0x56: "ぶい", 0x57: "だぶりゅー", 0x58: "えっくす",
        0x59: "わい", 0x5A: "ぜっと",
    ]

    // True for hiragana (after katakana folding) and the long-vowel mark.
    private static func isKana(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first else { return false }
        return (0x3041...0x3096).contains(scalar.value) || scalar.value == 0x30FC
    }

    // Hepburn romanization of a hiragana string (a reading may be several morae long). っ and
    // ー inside a reading resolve against their neighbours within the string.
    static func romanize(_ hiragana: String) -> String {
        var out = ""
        let chars = Array(hiragana)
        var i = 0
        while i < chars.count {
            let c = String(chars[i])
            let next = i + 1 < chars.count ? String(chars[i + 1]) : ""
            if c == "っ" {
                let following = romanize(String(chars[(i + 1)...]))
                if let f = following.first, vowels.contains(f) == false { out += String(f) }
                i += 1; continue
            }
            if c == "ー" {
                if let last = out.last, vowels.contains(last) { out += String(last) }
                i += 1; continue
            }
            if smallKana.contains(next), let combined = table[c + next] {
                out += combined; i += 2; continue
            }
            out += table[c] ?? ""
            i += 1
        }
        return out
    }

    private static let table: [String: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "i", "ゑ": "e", "を": "o", "ん": "n",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ゔ": "vu",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ゃ": "ya", "ゅ": "yu", "ょ": "yo",
        "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo", "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
        "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho", "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
        "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo", "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
        "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo", "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
        "じゃ": "ja", "じゅ": "ju", "じょ": "jo", "ぢゃ": "ja", "ぢゅ": "ju", "ぢょ": "jo",
        "びゃ": "bya", "びゅ": "byu", "びょ": "byo", "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
        "しぇ": "she", "じぇ": "je", "ちぇ": "che", "てぃ": "ti", "でぃ": "di", "とぅ": "tu", "どぅ": "du",
        "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo", "うぃ": "wi", "うぇ": "we", "うぉ": "wo",
        "ゔぁ": "va", "ゔぃ": "vi", "ゔぇ": "ve", "ゔぉ": "vo", "いぇ": "ye",
    ]
}
