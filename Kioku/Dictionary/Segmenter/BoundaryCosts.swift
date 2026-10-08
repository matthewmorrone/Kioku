import Foundation

// The boundary model's verdict on one text, as path-search costs: −weight·ln P(cut) at each gap a
// segment ends at and −weight·ln P(no cut) at each gap a segment spans, in whole centi-nats so the
// path search stays integer and deterministic. A segmentation's total is the sum over every gap, which
// splits exactly into one charge per segment — so it adds to viterbiSelect's node cost unchanged.
// Gap i (1..<n) is the gap before character i, as in BoundaryFeatures.
nonisolated struct BoundaryCosts: Sendable {
    // Prefix sums of the join cost: joinPrefix[i] is the cost of keeping gaps 1..<i uncut.
    private let joinPrefix: [Int]
    // Cut cost per gap, indexed 0...n; gaps 0 and n (text start and end) cost nothing.
    private let cut: [Int]

    // cutProbabilities[i - 1] is P(cut) at gap i, for gaps 1..<n of a text of n characters.
    init(cutProbabilities: [Double], weight: Double) {
        // Clamp so one confident gap can't make a path unaffordable outright.
        let floor = 1e-4
        let n = cutProbabilities.count + 1
        var cut = [Int](repeating: 0, count: n + 1)
        var join = [Int](repeating: 0, count: n + 1)
        for (offset, probability) in cutProbabilities.enumerated() {
            let p = min(max(probability, floor), 1 - floor)
            cut[offset + 1] = Int((-weight * log(p) * 100).rounded())
            join[offset + 1] = Int((-weight * log(1 - p) * 100).rounded())
        }
        var prefix = [Int](repeating: 0, count: n + 2)
        for i in 0...n { prefix[i + 1] = prefix[i] + join[i] }
        self.joinPrefix = prefix
        self.cut = cut
    }

    // What a segment covering characters start..<end adds: a join at every gap inside it and a cut
    // at its end. An absorbed bound character (LatticeEdge.isAbsorbedBoundCharacter) is folded into
    // the segment before it, so the gap at its start is a join, not the cut the previous segment paid.
    func cost(start: Int, end: Int, absorbed: Bool) -> Int {
        guard end > start, end < cut.count else { return 0 }
        var total = joinPrefix[end] - joinPrefix[start + 1] + cut[end]
        if absorbed, start > 0 { total += (joinPrefix[start + 1] - joinPrefix[start]) - cut[start] }
        return total
    }
}
