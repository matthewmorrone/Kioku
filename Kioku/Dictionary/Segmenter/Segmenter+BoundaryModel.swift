import Foundation

// The boundary model's part in path selection: one run of the model per text, turned into the
// per-gap costs viterbiSelect adds. Both segmentation (longestMatchResult) and the split editor's
// prices (splitCosts) take their costs from here, so the two can't disagree.
extension Segmenter {
    // How strongly the model's verdict counts against the word and transition costs: chosen on
    // train2k and its kana copies where cut-throughs bottom out (scripts/segmentation-eval/boundary).
    static let boundaryModelWeight = 4.0

    // The model's costs for text over this lattice, or nil when there is no model, nothing to
    // decide (one character), or no path to read its input from. The model is given the path the
    // search picks without it, as in training.
    func boundaryCosts(lattice: [LatticeEdge], in text: String) -> BoundaryCosts? {
        guard let boundaryModel, text.count > 1 else { return nil }
        let unaided = viterbiSelect(from: lattice, in: text).path
        guard unaided.isEmpty == false else { return nil }
        let path = absorbingBoundCharacters(in: unaided, of: text)
        guard let probabilities = boundaryModel.cutProbabilities(text: text, lattice: lattice, path: path) else { return nil }
        return BoundaryCosts(cutProbabilities: probabilities, weight: Self.boundaryModelWeight)
    }
}
