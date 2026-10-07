// SingPhonemeScorer.swift
//
// Sing mode's grade for one word: how much of the word's expected phoneme sequence the
// phoneme model hears, in order, inside the word's time window. The lyrics are the known
// target, so this never transcribes — it only asks whether the expected sounds are there.
// Each phoneme gets the frame where it peaks best (in order, one frame per phoneme, the way a
// CTC model spikes); it passes when its probability there clears a low bar. A word needs both
// its vowels (with ん) and its consonants: each group is scored on its own and the word's score
// is the lower share, so a vowel-only mumble doesn't pass. Vowel length is forgiven: a held vowel
// is one sound, and the lengthening う of おう / い of えい counts only when it is heard.

import Foundation

public enum SingPhonemeScorer {
    /// A phoneme counts as heard when its best in-order frame reaches this probability.
    public static let passProbability: Float = 0.15
    /// A word counts as sung when this share of its vowels and this share of its consonants are heard.
    public static let passFraction = 0.5
    /// Slack around the aligned word time: singers come in early and drag late.
    public static let leadSlackSec = 0.25
    public static let tailSlackSec = 0.35
    // At a line's first / last word the neighbour on that side is silence, so the window can widen.
    public static let lineEdgeLeadSlackSec = 0.6
    public static let lineEdgeTailSlackSec = 0.8

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

    // The word's score (0…1) in frames [first, last] of a row-major [frames × classes]
    // log-probability matrix: the lower of its heard-vowel and heard-consonant shares. 0 when the
    // window is shorter than the word.
    public static func score(tokens: [Int], logProbs: [Float], classes: Int, firstFrame: Int, lastFrame: Int) -> Double {
        scoreDetails(tokens: tokens, logProbs: logProbs, classes: classes, firstFrame: firstFrame, lastFrame: lastFrame).score
    }

    // The score plus, per token in order, the absolute frame it was placed on and its probability
    // there — what the diagnostics log prints to show where in the window each sound was found.
    public static func scoreDetails(tokens: [Int], logProbs: [Float], classes: Int, firstFrame: Int, lastFrame: Int)
        -> (score: Double, placements: [(frame: Int, probability: Float)]) {
        let k = tokens.count, t = lastFrame - firstFrame + 1
        guard k > 0, t >= k, firstFrame >= 0 else { return (0, []) }
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
        // Heard / total per group: [0] vowels and ん, [1] consonants.
        var heard = [0.0, 0.0], total = [0.0, 0.0]
        var placements = [(frame: Int, probability: Float)](repeating: (0, 0), count: k)
        for i in stride(from: k - 1, through: 0, by: -1) {
            let probability = exp(lp(f, tokens[i]))
            placements[i] = (firstFrame + f, probability)
            let isHeard = probability >= passProbability
            if isHeard || isLengthener(at: i, in: tokens) == false {
                let group = isVowelLike(tokens[i]) ? 0 : 1
                total[group] += 1
                if isHeard { heard[group] += 1 }
            }
            if i > 0 { f = from[i * t + f] }
        }
        let shares = (0..<2).compactMap { total[$0] > 0 ? heard[$0] / total[$0] : nil }
        return (shares.min() ?? 0, placements)
    }

    // The phoneme label for a token, for logs.
    public static func label(_ token: Int) -> Character {
        token < CTCEmissions.labels.count ? CTCEmissions.labels[token] : "?"
    }

    // Vowels and syllabic ん, scored as one group against the consonants.
    private static func isVowelLike(_ token: Int) -> Bool { (1...6).contains(token) }

    // True for the う right after an o or the い right after an e (こう, せい): usually sung as a
    // longer vowel rather than a sound of its own, so it only counts when the model hears it.
    private static func isLengthener(at i: Int, in tokens: [Int]) -> Bool {
        guard i > 0 else { return false }
        let pair = (label(tokens[i - 1]), label(tokens[i]))
        return pair == ("o", "u") || pair == ("e", "i")
    }
}
