import Foundation

// Viterbi path selection over the segmenter's lattice: word costs plus class-pair transition
// costs. Split out of Segmenter.swift to keep that file under the line-count guardrail — the
// lattice is built there (buildLattice), the cheapest path through it is chosen here.
// `viterbiSelect` is internal (not private) because longestMatchResult calls it from the other
// file, and the segmentation-eval CLI calls it directly.
extension Segmenter {
    // Selects the minimum-cost lattice path using Viterbi DP: word costs plus class-pair transition costs.
    // Wired into longestMatchResult behind SegmenterSettings.usesGlobalLongestMatch; this entry
    // point remains available for direct callers (diagnostics, tests).
    func viterbiBestPath(for text: String) -> [LatticeEdge] {
        let edges = buildLattice(for: text)
        return viterbiSelect(from: edges, in: text).path
    }

    // Runs Viterbi search over an already-built lattice. Returns the edges (annotated in place with
    // per-edge score / predecessor metadata for the diagnostic overlay) and the chosen path.
    // Pulled out of viterbiBestPath so longestMatchResult can share its lattice instead of rebuilding.
    func viterbiSelect(from inputEdges: [LatticeEdge], in text: String) -> (edges: [LatticeEdge], path: [LatticeEdge]) {
        var edges = inputEdges
        guard !edges.isEmpty else { return (edges: [], path: []) }

        var edgesByEnd: [String.Index: [Int]] = [:]
        for (i, edge) in edges.enumerated() { edgesByEnd[edge.end, default: []].append(i) }

        // Precompute character offsets for every edge endpoint once. String.distance is O(n) in
        // grapheme clusters, and calling it from inside a sort comparator turns Viterbi setup into
        // O(E log E · N) string traversal — large enough on real notes to trigger the iOS watchdog
        // and crash the app to home screen. Building offset arrays via a single index walk is O(N+E).
        var indexToCharOffset: [String.Index: Int] = [:]
        indexToCharOffset.reserveCapacity(text.count + 1)
        var walkIndex = text.startIndex
        var walkOffset = 0
        indexToCharOffset[walkIndex] = walkOffset
        while walkIndex < text.endIndex {
            walkIndex = text.index(after: walkIndex)
            walkOffset += 1
            indexToCharOffset[walkIndex] = walkOffset
        }

        let startOffsets = edges.map { indexToCharOffset[$0.start] ?? 0 }
        let endOffsets = edges.map { indexToCharOffset[$0.end] ?? 0 }

        let sortedIndices = edges.indices.sorted { li, ri in
            let le = endOffsets[li]
            let re = endOffsets[ri]
            if le == re { return startOffsets[li] < startOffsets[ri] }
            return le < re
        }

        // Each edge's transition class, resolved once; a bound character is folded into the segment
        // before it, so it is not a word in its own right and takes no part in the class sequence.
        let table = transitionTable
        let classIDs = edges.map { table?.classIDs(for: $0) }
        let boundaryIDs = table?.classIDs(for: nil)
        // Cost of edge `next` directly after edge `previous`; nil stands for the start or end of text.
        func transitionCost(_ previous: Int?, _ next: Int?) -> Int {
            guard let table, let boundaryIDs else { return 0 }
            if let previous, edges[previous].isAbsorbedBoundCharacter { return 0 }
            if let next, edges[next].isAbsorbedBoundCharacter { return 0 }
            let from = previous.flatMap { classIDs[$0] } ?? boundaryIDs
            let to = next.flatMap { classIDs[$0] } ?? boundaryIDs
            return table.cost(from: from, to: to)
        }

        var bestScore: [Int: Int] = [:]
        var back: [Int: Int?] = [:]
        // Breaks exact cost ties: fewer inflection steps along the path, then more segments — an
        // over-merge hides a word boundary from the reader, an over-split does not.
        var tieRank: [Int: Int] = [:]

        for i in sortedIndices {
            let edge = edges[i]
            let nodeCost = SegmenterScoring.edgeCost(edge)

            if edge.start == text.startIndex {
                let startCost = nodeCost + transitionCost(nil, i)
                bestScore[i] = startCost
                back[i] = nil
                tieRank[i] = edge.inflectionSteps * 1000 - 1
                edges[i].viterbiScore = startCost
                edges[i].viterbiPrevStart = startOffsets[i]
                continue
            }

            var bestT: Int?
            var bestPrev: Int?

            for prev in edgesByEnd[edge.start] ?? [] {
                guard let prevScore = bestScore[prev] else { continue }
                let t = transitionCost(prev, i)
                if shouldLogPOSTransitions && t != 0 {
                    AppLog.debug(.segmentation, "POS transition \(edges[prev].surface) → \(edge.surface) \(t)")
                }
                let score = prevScore + nodeCost + t
                let wins = bestT == nil || score < bestT! || (score == bestT! && (tieRank[prev] ?? 0) < (tieRank[bestPrev ?? prev] ?? 0))
                if wins { bestT = score; bestPrev = prev }
            }

            if let resolved = bestT {
                bestScore[i] = resolved
                back[i] = bestPrev
                tieRank[i] = (bestPrev.flatMap { tieRank[$0] } ?? 0) + edge.inflectionSteps * 1000 - 1
                edges[i].viterbiScore = resolved
                edges[i].viterbiPrevStart = bestPrev.map { startOffsets[$0] }
            }
        }

        // A path's total includes the transition from its last word into the end of text.
        let terminals = edges.indices.filter { edges[$0].end == text.endIndex && bestScore[$0] != nil }
        let terminalScore: (Int) -> Int = { index in
            (bestScore[index] ?? Int.max / 2) + transitionCost(index, nil)
        }
        guard let best = terminals.min(by: {
            (terminalScore($0), tieRank[$0] ?? 0) < (terminalScore($1), tieRank[$1] ?? 0)
        }) else {
            return (edges: edges, path: [])
        }

        var pathIndices: [Int] = []
        var cur: Int? = best
        while let idx = cur { pathIndices.append(idx); cur = back[idx] ?? nil }
        let path = pathIndices.reversed().map { edges[$0] }
        return (edges: edges, path: path)
    }
}
