// CTCViterbi.swift
//
// CTC forced alignment: the maximum-likelihood monotonic path of a known token sequence
// through per-frame log-probabilities (blank = class 0). Standard 2L+1-state trellis; frames a
// token state occupies form that token's span. Exact and monotonic by construction, which is
// what makes repeated chorus lines unambiguous: the DP has to place the first repeat's text
// before the second's, and the acoustics decide where each lands.

import Foundation

public enum CTCViterbi {
    // `logProbs` is row-major [frames × classes]. Returns one (startFrame, endFrame-exclusive)
    // span per token, or nil when no monotonic path exists (more tokens than frames allow).
    public static func align(logProbs: [Float], frames: Int, classes: Int, tokens: [Int]) -> [(start: Int, end: Int)]? {
        let L = tokens.count
        guard L > 0, frames > 0 else { return nil }
        let S = 2 * L + 1
        let neg = -Float.infinity
        // label for state s: even → blank, odd → tokens[(s-1)/2]
        @inline(__always) func label(_ s: Int) -> Int { s & 1 == 1 ? tokens[(s - 1) / 2] : 0 }
        // Skipping the blank between two tokens is only allowed when they differ.
        @inline(__always) func canSkip(_ s: Int) -> Bool { s >= 3 && s & 1 == 1 && tokens[(s - 1) / 2] != tokens[(s - 3) / 2] }

        var prev = [Float](repeating: neg, count: S)
        var cur = [Float](repeating: neg, count: S)
        var back = [UInt8](repeating: 0, count: frames * S)   // 0: stay, 1: from s-1, 2: from s-2
        prev[0] = logProbs[0]
        prev[1] = logProbs[label(1)]
        for t in 1..<frames {
            let row = t * classes
            let bp = t * S
            // States reachable at frame t must leave room for the remaining tokens.
            let sMin = max(0, S - 2 * (frames - t))
            for s in 0..<S {
                if s < sMin { cur[s] = neg; continue }
                var best = prev[s]; var arg: UInt8 = 0
                if s >= 1, prev[s - 1] > best { best = prev[s - 1]; arg = 1 }
                if canSkip(s), prev[s - 2] > best { best = prev[s - 2]; arg = 2 }
                cur[s] = best == neg ? neg : best + logProbs[row + label(s)]
                back[bp + s] = arg
            }
            swap(&prev, &cur)
        }
        var s = prev[S - 1] >= prev[S - 2] ? S - 1 : S - 2
        guard prev[s] > neg else { return nil }

        var spans = [(start: Int, end: Int)](repeating: (0, 0), count: L)
        var t = frames - 1
        while true {
            if s & 1 == 1 {
                let k = (s - 1) / 2
                if spans[k].end == 0 { spans[k].end = t + 1 }
                spans[k].start = t
            }
            if t == 0 { break }
            s -= Int(back[t * S + s])
            t -= 1
        }
        return spans
    }
}
