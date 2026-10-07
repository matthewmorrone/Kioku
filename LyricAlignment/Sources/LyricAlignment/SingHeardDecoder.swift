// SingHeardDecoder.swift
//
// What the phoneme model thinks the singer said over a stretch of frames, in kana, for Sing
// mode's live "heard" line. Unlike SingPhonemeScorer this ignores the lyric: it takes the most
// likely label on every frame (greedy CTC), drops blanks and pauses, collapses repeats, and spells
// the phonemes back as kana. A consonant the model heard with no vowel after it is left out.

import Foundation

public enum SingHeardDecoder {
    // Kana for frames [firstFrame, lastFrame] of a row-major [frames × classes] log-probability
    // matrix; empty when the model heard nothing there.
    public static func kana(logProbs: [Float], classes: Int, firstFrame: Int, lastFrame: Int) -> String {
        guard firstFrame >= 0, lastFrame >= firstFrame, (lastFrame + 1) * classes <= logProbs.count else { return "" }
        var phonemes: [Character] = []
        var previous = -1
        for f in firstFrame...lastFrame {
            let row = f * classes
            var best = 0
            for c in 1..<classes where logProbs[row + c] > logProbs[row + best] { best = c }
            defer { previous = best }
            guard best != previous, best != CTCEmissions.blank, best < CTCEmissions.labels.count else { continue }
            let label = CTCEmissions.labels[best]
            if label != "*" { phonemes.append(label) }
        }
        return spell(phonemes)
    }

    // Phoneme labels → kana: onset + vowel pairs, lone vowels, ん and っ.
    static func spell(_ phonemes: [Character]) -> String {
        var out = ""
        var onset: Character?
        for p in phonemes {
            if let v = vowelIndex[p] {
                if let o = onset, let row = onsetRows[o] { out += row[v] } else { out += plainVowels[v] }
                onset = nil
            } else if p == "N" {
                out += "ん"; onset = nil
            } else if p == "Q" {
                out += "っ"; onset = nil
            } else {
                onset = p
            }
        }
        return out
    }

    private static let vowelIndex: [Character: Int] = ["a": 0, "i": 1, "u": 2, "e": 3, "o": 4]
    private static let plainVowels = ["あ", "い", "う", "え", "お"]
    // Kana for each onset label (RomajiPhonemes' alphabet) before a, i, u, e, o.
    private static let onsetRows: [Character: [String]] = [
        "k": ["か", "き", "く", "け", "こ"], "g": ["が", "ぎ", "ぐ", "げ", "ご"],
        "s": ["さ", "すぃ", "す", "せ", "そ"], "z": ["ざ", "ずぃ", "ず", "ぜ", "ぞ"],
        "t": ["た", "てぃ", "とぅ", "て", "と"], "d": ["だ", "でぃ", "どぅ", "で", "ど"],
        "n": ["な", "に", "ぬ", "ね", "の"], "h": ["は", "ひ", "ふ", "へ", "ほ"],
        "b": ["ば", "び", "ぶ", "べ", "ぼ"], "p": ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        "m": ["ま", "み", "む", "め", "も"], "y": ["や", "い", "ゆ", "いぇ", "よ"],
        "r": ["ら", "り", "る", "れ", "ろ"], "w": ["わ", "うぃ", "う", "うぇ", "を"],
        "f": ["ふぁ", "ふぃ", "ふ", "ふぇ", "ふぉ"], "j": ["じゃ", "じ", "じゅ", "じぇ", "じょ"],
        "v": ["ゔぁ", "ゔぃ", "ゔ", "ゔぇ", "ゔぉ"],
        "S": ["しゃ", "し", "しゅ", "しぇ", "しょ"], "C": ["ちゃ", "ち", "ちゅ", "ちぇ", "ちょ"],
        "T": ["つぁ", "つぃ", "つ", "つぇ", "つぉ"], "K": ["きゃ", "き", "きゅ", "きぇ", "きょ"],
        "G": ["ぎゃ", "ぎ", "ぎゅ", "ぎぇ", "ぎょ"], "Y": ["にゃ", "に", "にゅ", "にぇ", "にょ"],
        "H": ["ひゃ", "ひ", "ひゅ", "ひぇ", "ひょ"], "B": ["びゃ", "び", "びゅ", "びぇ", "びょ"],
        "P": ["ぴゃ", "ぴ", "ぴゅ", "ぴぇ", "ぴょ"], "M": ["みゃ", "み", "みゅ", "みぇ", "みょ"],
        "R": ["りゃ", "り", "りゅ", "りぇ", "りょ"],
    ]
}
