// RomajiPhonemes.swift
//
// Turns one LyricRomanizer span (Hepburn romaji) into the OpenJTalk phoneme sequence the
// HuBERT phoneme aligner emits, one Character per phoneme in CTCEmissions.labels. The romaji
// is a lossless spelling of the app's kana readings, so the mapping is mechanical: っ (a doubled
// consonant, or a lone consonant span) → cl, syllabic ん → N, palatal / affricate onsets → their
// single phonemes (sh, ch, ts, ky …), a long vowel stays a repeated vowel as OpenJTalk writes it.

import Foundation

enum RomajiPhonemes {
    private static let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
    // Onset phoneme → label Character (vowels, N and cl are handled inline).
    private static let onsetLabel: [String: Character] = [
        "k": "k", "g": "g", "s": "s", "z": "z", "t": "t", "d": "d", "n": "n", "h": "h", "b": "b", "p": "p",
        "m": "m", "y": "y", "r": "r", "w": "w", "f": "f", "j": "j", "v": "v",
        "sh": "S", "ch": "C", "ts": "T", "ky": "K", "gy": "G", "ny": "Y", "hy": "H", "by": "B", "py": "P",
        "my": "M", "ry": "R",
    ]
    // Romaji onsets whose phoneme isn't their spelling.
    private static let onsetOverride: [String: String] = ["shi": "sh", "chi": "ch", "tsu": "ts", "fu": "f", "ji": "j"]

    // Phoneme label string for one romaji span; letters it can't place are dropped.
    static func encode(_ romaji: String) -> String {
        let c = Array(romaji)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            if vowels.contains(ch) { out.append(ch); i += 1; continue }
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            // Syllabic ん: an n not followed by a vowel or y.
            if ch == "n", next.map({ vowels.contains($0) || $0 == "y" }) != true { out.append("N"); i += 1; continue }
            // っ: a doubled consonant (tt, kk, "tch"), or a lone consonant span (LyricRomanizer's っ before the next span).
            if next == nil || next == ch || (ch == "t" && next == "c") { out.append("Q"); i += 1; continue }
            // Onset: the longest run of consonant letters before the vowel (sh, ch, ts, ky, …).
            var j = i
            while j < c.count, vowels.contains(c[j]) == false { j += 1 }
            guard j < c.count else { i = j; continue }
            let onset = String(c[i..<j]), syllable = onset + String(c[j])
            let phoneme = onsetOverride[syllable] ?? onset
            if let label = onsetLabel[phoneme] { out.append(label) } else if let first = phoneme.first, let label = onsetLabel[String(first)] {
                // ti, di, tu, du, she, je, che, fa, wi, ye … : the plain consonant (or sh/ch/j) before the vowel.
                out.append(onsetLabel[String(phoneme.prefix(2))] ?? label)
            }
            out.append(c[j])
            i = j + 1
        }
        return out
    }
}
