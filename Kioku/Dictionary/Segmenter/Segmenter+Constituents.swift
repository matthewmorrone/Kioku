import Foundation

// The smaller segments a segment is made of. Segmentation keeps 歌い続けてゆく one word because that
// is its cheapest path; this answers the other question — what is it built from — with the same path
// search, so the pieces are the ones segmentation itself would choose were the whole not a word.
extension Segmenter {
    // The segments `surface` breaks into when its own whole-text edge is not allowed: the cheapest
    // path through the rest of its lattice, scored exactly as segmentation scores a line (word costs,
    // class transitions, boundary model). `margin` is how much dearer that split is than the
    // cheapest path over the whole lattice (centi-nats): near zero for a compound the scorer almost
    // kept apart, large for a word that is plainly one (学校). Nil when no path of two or more segments
    // covers the text. A te-form stays whole (歌い|続けて|ゆく, not 続け|て) because the search prices
    // 続けて as one word, as it does in a line. Deterministic for a fixed surface and dictionary.
    func constituentSegments(of surface: String) -> (pieces: [LatticeEdge], margin: Int)? {
        guard surface.isEmpty == false else { return nil }
        let lattice = buildLattice(for: surface)
        let parts = lattice.filter { $0.start != surface.startIndex || $0.end != surface.endIndex }
        guard parts.isEmpty == false else { return nil }
        let costs = boundaryCosts(lattice: lattice, in: surface)
        let whole = viterbiSelect(from: lattice, in: surface, boundaryCosts: costs).cost
        let split = viterbiSelect(from: parts, in: surface, boundaryCosts: costs)
        guard split.path.isEmpty == false, let splitCost = split.cost else { return nil }
        let pieces = absorbingBoundCharacters(in: split.path, of: surface)
        guard pieces.count > 1 else { return nil }
        return (pieces, splitCost - (whole ?? splitCost))
    }
}
