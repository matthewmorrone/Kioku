// LyricRomanizer.swift
//
// Turns one lyric line into the romanized spans the forced aligner reads (see
// SwiftWhisperAlign.RomanizedSpan): kanji runs get their dictionary reading from the same
// furigana resolver the reader uses, kana is transliterated directly, and every span remembers
// the UTF-16 range of the line it came from so the aligner's times land back on the text.

import Foundation
import SwiftWhisperAlign

struct LyricRomanizer {
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
            } else {
                offset += width   // punctuation, Latin, digits: no span
            }
        }

        // Romanize with the context っ and ー need from their neighbours.
        var romaji = morae.map { Self.romanize($0.kana) }
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

    private static let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
    private static let smallKana: Set<String> = ["ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]

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
