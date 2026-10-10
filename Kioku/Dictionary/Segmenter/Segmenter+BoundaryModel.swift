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
        return BoundaryCosts(cutProbabilities: Self.withoutDigitGapVerdicts(probabilities, in: text), weight: Self.boundaryModelWeight)
    }

    // Sets every gap between two digits (script class 5; kanji numerals count as kanji) to 0.5, a cut
    // and a join priced alike, so the model has no say there. Training masks the gaps no gold token
    // covers, and gold leaves numbers outside its tokens, so the model has never been taught a
    // digit–digit gap: its guess there is noise, and at its weight that noise split ２０２ into ２０|２
    // (a dictionary entry plus a digit).
    static func withoutDigitGapVerdicts(_ probabilities: [Double], in text: String) -> [Double] {
        let characters = Array(text)
        var adjusted = probabilities
        for gap in 1..<characters.count where gap - 1 < adjusted.count {
            if BoundaryFeatures.scriptClass(characters[gap - 1]) == 5, BoundaryFeatures.scriptClass(characters[gap]) == 5 {
                adjusted[gap - 1] = 0.5
            }
        }
        return adjusted
    }
}
