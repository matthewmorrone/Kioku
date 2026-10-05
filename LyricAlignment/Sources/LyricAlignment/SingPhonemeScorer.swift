// SingPhonemeScorer.swift
//
// Sing mode's grade for one word: how much of the word's expected phoneme sequence the
// phoneme model hears, in order, inside the word's time window. The lyrics are the known
// target, so this never transcribes — it only asks whether the expected sounds are there.
// Each phoneme gets the frame where it peaks best (in order, one frame per phoneme, the way a
// CTC model spikes); it passes when its probability there clears a low bar. Vowels and ん count
// double because sung consonants are often swallowed. Lenient on purpose: marking a word the
// singer knew as missed costs more than letting a mumble through.

import Foundation

public enum SingPhonemeScorer {
    /// A phoneme counts as heard when its best in-order frame reaches this probability.
    public static let passProbability: Float = 0.15
    /// A word counts as sung when this share of its (weighted) phonemes is heard.
    public static let passFraction = 0.6
    /// Slack around the aligned word time: singers come in early and drag late.
    public static let leadSlackSec = 0.25
    public static let tailSlackSec = 0.35

    // Phoneme tokens for a word from its romaji spans. っ (Q) is dropped (a silent gap the
    // model rarely marks in singing) and repeats collapse, since a held long vowel is one sound.
    public static func tokens(fromRomaji spans: [String]) -> [Int] {
        var out: [Int] = []
        for ch in spans.map(RomajiPhonemes.encode).joined() {
            guard ch != "Q", let index = CTCEmissions.labels.firstIndex(of: ch) else { continue }
            if out.last == index { continue }
            out.append(index)
        }
        return out
    }

    // Weighted share (0…1) of `tokens` heard in frames [first, last] of a row-major
    // [frames × classes] log-probability matrix. 0 when the window is shorter than the word.
    public static func score(tokens: [Int], logProbs: [Float], classes: Int, firstFrame: Int, lastFrame: Int) -> Double {
        let k = tokens.count, t = lastFrame - firstFrame + 1
        guard k > 0, t >= k, firstFrame >= 0 else { return 0 }
        @inline(__always) func lp(_ f: Int, _ token: Int) -> Float { logProbs[(firstFrame + f) * classes + token] }

        // best[i][f]: best summed log-prob placing tokens 0…i with token i on frame f (frames strictly increasing).
        // from[i][f]: frame token i-1 sits on in that placement, for the backtrack.
        var best = [Float](repeating: -.infinity, count: k * t)
        var from = [Int](repeating: -1, count: k * t)
        for f in 0..<t { best[f] = lp(f, tokens[0]) }
        for i in 1..<k {
            var runMax: Float = -.infinity, runArg = -1
            for f in i..<t {
                let prev = best[(i - 1) * t + f - 1]
                if prev > runMax { runMax = prev; runArg = f - 1 }
                best[i * t + f] = runMax + lp(f, tokens[i])
                from[i * t + f] = runArg
            }
        }
        var f = (k - 1..<t).max { best[(k - 1) * t + $0] < best[(k - 1) * t + $1] } ?? (t - 1)
        var heard = 0.0, total = 0.0
        for i in stride(from: k - 1, through: 0, by: -1) {
            let weight = isVowelLike(tokens[i]) ? 2.0 : 1.0
            total += weight
            if exp(lp(f, tokens[i])) >= passProbability { heard += weight }
            if i > 0 { f = from[i * t + f] }
        }
        return heard / total
    }

    // Vowels and syllabic ん: the sounds that survive singing.
    private static func isVowelLike(_ token: Int) -> Bool { (1...6).contains(token) }
}
