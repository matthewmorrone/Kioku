// SingPhonemeScorer.swift
//
// Sing mode's grade for a run of words: how much of each word's expected phoneme sequence the
// phoneme model hears, in order, across the audio sung since the previous word. The lyrics are the known
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
    /// Frames either side of a sound's placed frame whose probabilities are summed: a sung note
    /// spreads the model's confidence over several frames instead of one spike, so the single-frame
    /// peak understates it.
    nonisolated(unsafe) public static var massFrames = 2
    /// The most frames that may separate two consecutive sounds of one word (0: no limit). Sung
    /// sounds follow each other closely; without a limit a word's sounds can be picked from
    /// seconds apart and almost any word is "found" somewhere in a long stretch of audio.
    nonisolated(unsafe) public static var maxGapFrames = 25
    /// A word counts as sung when this share of its vowels and this share of its consonants are heard.
    public static let passFraction = 0.5

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

    // Sing's grade, with no song clock to time it: each word's score
    // (0…1) when all the words' sounds are placed in order across frames [first, last], so a word
    // is found wherever the singer put it, with the absolute frames its first and last sounds were
    // placed on (the last is where the next word's search can start once this one counts as
    // heard). Each word is scored by the lower of its heard-vowel and heard-consonant shares. All
    // zeros, with no frames, when the window is shorter than the words.
    public static func wordScores(words: [[Int]], logProbs: [Float], classes: Int, firstFrame: Int, lastFrame: Int)
        -> [(score: Double, firstFrame: Int?, lastFrame: Int?)] {
        let joined = words.flatMap { $0 }
        var wordStarts = Set<Int>()
        var running = 0
        for word in words { wordStarts.insert(running); running += word.count }
        guard let placements = bestPlacements(tokens: joined, wordStarts: wordStarts, logProbs: logProbs, classes: classes,
                                              firstFrame: firstFrame, lastFrame: lastFrame) else {
            return words.map { _ in (0, nil, nil) }
        }
        var offset = 0
        return words.map { word in
            defer { offset += word.count }
            let placed = placements[offset..<(offset + word.count)]
            return (share(tokens: word, probabilities: placed.map(\.probability)), placed.first?.frame, placed.last?.frame)
        }
    }

    // Per token in order, the absolute frame of its best in-order placement (frames strictly
    // increasing, best summed log-probability) and its probability there; nil when the window
    // is shorter than the tokens.
    private static func bestPlacements(tokens: [Int], wordStarts: Set<Int>, logProbs: [Float], classes: Int, firstFrame: Int, lastFrame: Int)
        -> [(frame: Int, probability: Float)]? {
        let k = tokens.count, t = lastFrame - firstFrame + 1
        guard k > 0, t >= k, firstFrame >= 0 else { return nil }
        @inline(__always) func lp(_ f: Int, _ token: Int) -> Float { logProbs[(firstFrame + f) * classes + token] }

        // best[i][f]: best summed log-prob placing tokens 0…i with token i on frame f (frames strictly increasing).
        // from[i][f]: frame token i-1 sits on in that placement, for the backtrack.
        var best = [Float](repeating: -.infinity, count: k * t)
        var from = [Int](repeating: -1, count: k * t)
        for f in 0..<t { best[f] = lp(f, tokens[0]) }
        for i in 1..<k {
            if maxGapFrames > 0, wordStarts.contains(i) == false {
                // Inside a word: the previous sound must be at most `maxGapFrames` back.
                for f in i..<t {
                    var bestPrev: Float = -.infinity, arg = -1
                    for g in max(i - 1, f - maxGapFrames)...(f - 1) where best[(i - 1) * t + g] > bestPrev {
                        bestPrev = best[(i - 1) * t + g]; arg = g
                    }
                    best[i * t + f] = bestPrev + lp(f, tokens[i])
                    from[i * t + f] = arg
                }
                continue
            }
            var runMax: Float = -.infinity, runArg = -1
            for f in i..<t {
                let prev = best[(i - 1) * t + f - 1]
                if prev > runMax { runMax = prev; runArg = f - 1 }
                best[i * t + f] = runMax + lp(f, tokens[i])
                from[i * t + f] = runArg
            }
        }
        var f = (k - 1..<t).max { best[(k - 1) * t + $0] < best[(k - 1) * t + $1] } ?? (t - 1)
        var placements = [(frame: Int, probability: Float)](repeating: (0, 0), count: k)
        for i in stride(from: k - 1, through: 0, by: -1) {
            var probability = exp(lp(f, tokens[i]))
            if massFrames > 0 {
                var mass: Float = 0
                for near in max(0, f - massFrames)...min(t - 1, f + massFrames) { mass += exp(lp(near, tokens[i])) }
                probability = min(1, max(probability, mass))
            }
            placements[i] = (firstFrame + f, probability)
            if i > 0 { f = from[i * t + f] }
        }
        return placements
    }

    // A word's score from its tokens' placement probabilities: the lower of its heard-vowel and
    // heard-consonant shares, a lengthening vowel counting only when heard.
    private static func share(tokens: [Int], probabilities: [Float]) -> Double {
        // Heard / total per group: [0] vowels and ん, [1] consonants.
        var heard = [0.0, 0.0], total = [0.0, 0.0]
        for (i, probability) in probabilities.enumerated() {
            let isHeard = probability >= passProbability
            if isHeard || isLengthener(at: i, in: tokens) == false {
                let group = isVowelLike(tokens[i]) ? 0 : 1
                total[group] += 1
                if isHeard { heard[group] += 1 }
            }
        }
        let shares = (0..<2).compactMap { total[$0] > 0 ? heard[$0] / total[$0] : nil }
        return shares.min() ?? 0
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
