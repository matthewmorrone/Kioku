// AlignmentFit.swift
//
// Tells whether an alignment matches the audio without trusting the lyrics. The model's raw
// phoneme stream for a line's time span is decoded greedily (argmax per frame, repeats collapsed,
// blank and star dropped) and compared with the phonemes the lyric line predicts there. A line fits
// when its own span decodes closer to its text than other lines' spans do: that margin is large
// for a correct placement and near zero for a slid or swapped one, and, unlike the model's peak
// probability, it does not depend on how clearly the singer enunciates.

import Foundation

public enum AlignmentFit {
    // The mean fit below which an alignment is worth a warning. On six fixtures the true timings
    // scored 0.40–0.61 and the same timings slid 4 s or by one line 0.14 or less; the aligner's
    // own placement of 乙女のススメ scored 0.44. Lyrics that merely differ on some lines (two
    // missing stanzas scored 0.32) fall between and are not caught.
    public static let warningThreshold: Float = 0.25

    // A line fitting below this sounds no better in its own span than in a typical other one.
    public static let weakLineThreshold: Float = 0.1

    // Fewer lines than this leave too little to compare a line against.
    private static let minLines = 4

    // The fit of each line, 0...1: the median over the other lines' spans of that line's phoneme
    // error rate there, minus its error rate at its own span, floored at 0. Nil for a line with no
    // phonemes, and for every line when there are too few to compare.
    static func margins(
        lines: [AlignedLine], romanization: [[RomanizedSpan]],
        stem: CTCEmissions.Matrix, mix: CTCEmissions.Matrix
    ) -> [Float?] {
        let expected = romanization.map { spans in spans.map { RomajiPhonemes.encode($0.romaji) }.joined() }
        guard lines.count == expected.count, lines.count >= minLines else { return [Float?](repeating: nil, count: lines.count) }
        // Each span is decoded once per matrix, then every line is compared with every span.
        let decoded = lines.map { line in [stem, mix].map { decode($0, from: line.start, to: line.end) } }
        return expected.indices.map { i in
            let target = Array(expected[i])
            guard target.isEmpty == false else { return nil }
            let errorRates = decoded.map { candidates in
                candidates.map { Float(editDistance(target, $0)) / Float(target.count) }.min() ?? 1
            }
            let others = errorRates.enumerated().filter { $0.offset != i }.map(\.element).sorted()
            let median = others[others.count / 2]
            return max(0, min(1, median - errorRates[i]))
        }
    }

    // The phonemes the model hears between two times: the per-frame best class, repeats collapsed,
    // blank and star dropped, as label characters.
    private static func decode(_ matrix: CTCEmissions.Matrix, from start: Double, to end: Double) -> [Character] {
        let classes = CTCEmissions.classes
        let star = CTCEmissions.labels.firstIndex(of: "*")
        let first = max(0, Int(start / matrix.frameSec)), last = min(matrix.frames, Int(end / matrix.frameSec))
        var out: [Character] = []
        var previous = -1
        var frame = first
        while frame < last {
            var best = 0
            for c in 1..<classes where matrix.values[frame * classes + c] > matrix.values[frame * classes + best] { best = c }
            if best != previous, best != CTCEmissions.blank, best != star { out.append(CTCEmissions.labels[best]) }
            previous = best
            frame += 1
        }
        return out
    }

    // Levenshtein distance: the phoneme insertions, deletions and substitutions between a line's
    // predicted and heard phonemes.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
