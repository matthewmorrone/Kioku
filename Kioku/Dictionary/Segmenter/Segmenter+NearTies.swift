import Foundation

// How confident the path search is in each cut of a line, measured with the split editor's own
// pricing (splitCosts) so a confidence can never disagree with the costs the lookup sheet shows.
extension Segmenter {
    // For every segment and every pair of neighbouring segments on the line's chosen path, prices the span kept whole and cut once at each position, and reports the cheapest cut that
    // differs from the chosen one with its extra cost. Single segments catch over-merges (one more
    // cut); pairs catch over-splits (ドロップ|ス → ドロップス) and misplaced cuts (お|菓子箱 →
    // お菓子|箱). Sorted by margin, smallest (least confident) first. Works on the path before bound
    // characters are folded in (ネ|ー, shown as ネー), since the folded form has no lattice edge of its
    // own and would be priced as unknown text.
    func nearTies(in text: String) -> [SegmentationNearTie] {
        let lattice = buildLattice(for: text)
        let path = viterbiSelect(from: lattice, in: text).path
        guard path.isEmpty == false else { return [] }
        var windows: [[LatticeEdge]] = path.map { [$0] }
        if path.count > 1 {
            windows += (0..<(path.count - 1)).map { [path[$0], path[$0 + 1]] }
        }

        var ties: [SegmentationNearTie] = []
        for window in windows {
            guard let first = window.first, let last = window.last else { continue }
            let range = first.start..<last.end
            let characters = Array(text[range])
            let chosen = window.map(\.surface)
            // Kept whole, plus every single cut; the chosen cut is one of these for any window.
            var candidates: [[String]] = [[String(characters)]]
            if characters.count > 1 {
                candidates += (1..<characters.count).map { [String(characters[..<$0]), String(characters[$0...])] }
            }
            if candidates.contains(chosen) == false { candidates.append(chosen) }
            let costs = splitCosts(of: range, in: text, candidates: candidates, lattice: lattice)
            guard let chosenIndex = candidates.firstIndex(of: chosen), let chosenCost = costs[chosenIndex] else { continue }
            // The cheapest alternative to the chosen cut, if any could be priced.
            let best = candidates.indices
                .filter { $0 != chosenIndex }
                .compactMap { index in costs[index].map { (pieces: candidates[index], cost: $0) } }
                .min { $0.cost < $1.cost }
            guard let best else { continue }
            ties.append(SegmentationNearTie(range: range, chosen: chosen, alternative: best.pieces, margin: best.cost - chosenCost))
        }
        return ties.sorted { $0.margin < $1.margin }
    }
}
