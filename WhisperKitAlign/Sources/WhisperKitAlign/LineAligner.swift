// LineAligner.swift
// Maps input text lines → WhisperKit transcription segments using DP
// on character bigram Jaccard similarity, then merges matched segment
// spans into per-line [start, end] intervals.
//
// Why DP: greedy left-to-right matching commits early and can leave
// later lines without a segment. DP finds the globally cheapest
// monotone assignment across all lines × segments simultaneously.

import Foundation

public struct LineAligner {

    /// Align `lines` to `segments`, returning one AlignedLine per input line.
    public static func align(
        lines: [String],
        segments: [TranscriptionSegment]
    ) -> [AlignedLine] {
        guard !lines.isEmpty, !segments.isEmpty else { return [] }
        let costs      = buildCostMatrix(lines: lines, segments: segments)
        let assignment = dpAssign(lineCount: lines.count,
                                  segCount: segments.count,
                                  costs: costs)
        return buildAlignedLines(lines: lines, segments: segments, assignment: assignment)
    }
}

// MARK: - Cost matrix (1 − Jaccard on character bigrams)

private func buildCostMatrix(
    lines: [String],
    segments: [TranscriptionSegment]
) -> [[Double]] {
    let lineBigrams = lines.map    { characterBigrams(normalize($0)) }
    let segBigrams  = segments.map { characterBigrams(normalize($0.text)) }
    return lineBigrams.map { lb in segBigrams.map { sb in 1.0 - jaccard(lb, sb) } }
}

private func normalize(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
     .precomposedStringWithCanonicalMapping
}

private func characterBigrams(_ s: String) -> [String: Int] {
    let chars = Array(s)
    guard chars.count > 1 else { return chars.isEmpty ? [:] : [String(chars[0]): 1] }
    var result: [String: Int] = [:]
    for i in 0 ..< chars.count - 1 {
        result[String(chars[i]) + String(chars[i + 1]), default: 0] += 1
    }
    return result
}

private func jaccard(_ a: [String: Int], _ b: [String: Int]) -> Double {
    var intersection = 0, union = 0
    for key in Set(a.keys).union(b.keys) {
        let av = a[key, default: 0], bv = b[key, default: 0]
        intersection += min(av, bv); union += max(av, bv)
    }
    return union == 0 ? 0.0 : Double(intersection) / Double(union)
}

// MARK: - DP: monotone assignment of lines to contiguous segment runs

/// Returns one Range<Int> per line: the half-open range of segments assigned to it.
/// Handles two cases:
///   S >= L — each line gets one or more segments (no sharing).
///   S < L  — lines share segments; each line is anchored to exactly one segment.
private func dpAssign(
    lineCount L: Int,
    segCount S: Int,
    costs: [[Double]]
) -> [Range<Int>] {
    return S >= L
        ? dpSpanning(L: L, S: S, costs: costs)
        : dpSharing(L: L, S: S, costs: costs)
}

/// S >= L: each line gets a contiguous run of one or more segments.
/// dp[l][s] = min cost assigning lines 0..<l using exactly segments 0..<s.
private func dpSpanning(L: Int, S: Int, costs: [[Double]]) -> [Range<Int>] {
    let inf = Double.infinity
    var dp    = Array(repeating: Array(repeating: inf, count: S + 1), count: L + 1)
    var split = Array(repeating: Array(repeating: 0,   count: S + 1), count: L + 1)
    dp[0][0] = 0.0

    for l in 1 ... L {
        // s in [l, S-(L-l)]: at least l segments used, enough remain for later lines.
        let sLow  = l
        let sHigh = S - (L - l)
        guard sLow <= sHigh else { continue }
        for s in sLow ... sHigh {
            for k in (l - 1) ..< s {
                guard dp[l - 1][k] < inf else { continue }
                var best = inf
                for seg in k ..< s { best = min(best, costs[l - 1][seg]) }
                let candidate = dp[l - 1][k] + best
                if candidate < dp[l][s] {
                    dp[l][s] = candidate
                    split[l][s] = k
                }
            }
        }
    }

    var ranges = [Range<Int>](repeating: 0 ..< 0, count: L)
    var s = S
    for l in stride(from: L, through: 1, by: -1) {
        let k = split[l][s]; ranges[l - 1] = k ..< s; s = k
    }
    return ranges
}

/// S < L: multiple lines can share a segment; each line gets exactly one anchor.
/// dp[l][s] = min cost of assigning lines 0..<l where line l-1 is anchored to segment s.
/// Monotone: line l may only use segment s' >= the segment used by line l-1.
private func dpSharing(L: Int, S: Int, costs: [[Double]]) -> [Range<Int>] {
    let inf = Double.infinity
    var dp   = Array(repeating: Array(repeating: inf, count: S), count: L)
    var from = Array(repeating: Array(repeating: 0,   count: S), count: L)

    for s in 0 ..< S { dp[0][s] = costs[0][s] }

    for l in 1 ..< L {
        for s in 0 ..< S {
            for k in 0 ... s {
                guard dp[l - 1][k] < inf else { continue }
                let candidate = dp[l - 1][k] + costs[l][s]
                if candidate < dp[l][s] {
                    dp[l][s] = candidate
                    from[l][s] = k
                }
            }
        }
    }

    var ranges = [Range<Int>](repeating: 0 ..< 1, count: L)
    var s = (0 ..< S).min(by: { dp[L - 1][$0] < dp[L - 1][$1] }) ?? 0
    for l in stride(from: L - 1, through: 0, by: -1) {
        ranges[l] = s ..< (s + 1)
        if l > 0 { s = from[l][s] }
    }
    return ranges
}

// MARK: - Build output

private func buildAlignedLines(
    lines: [String],
    segments: [TranscriptionSegment],
    assignment: [Range<Int>]
) -> [AlignedLine] {
    lines.enumerated().map { i, line in
        let range = assignment[i]
        let segs  = range.isEmpty ? [] : Array(segments[range])
        let start = segs.first?.start ?? segments.first?.start ?? 0
        let end   = segs.last?.end   ?? segments.last?.end   ?? 0
        return AlignedLine(text: line, start: start, end: end)
    }
}
