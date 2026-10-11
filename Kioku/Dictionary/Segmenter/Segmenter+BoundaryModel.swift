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
        let adjusted = Self.withAppleTokenHint(Self.withoutDigitGapVerdicts(probabilities, in: text), in: text)
        return BoundaryCosts(cutProbabilities: adjusted, weight: Self.boundaryModelWeight)
    }

    // How much less likely a cut is inside a word Apple's tokenizer keeps whole. Fitted on train2k
    // (P(cut) × 1: 74 cut-throughs, × 0.5: 72, × 0.05: 68, × 0.001: 71); held2k 63 → 61,
    // kana2k 216 → 201, fresh5k 67 → 63.
    static let appleTokenCutFactor = 0.05

    // Scales P(cut) at every gap strictly inside a token Apple's Japanese tokenizer
    // (CFStringTokenizer) keeps whole. Its tokens are shorter than Kioku's words (なり|まし|た), so
    // its boundaries are no guide, but it rarely puts a boundary-free span across a real word
    // boundary: on held2k it cuts through 24 gold words to the path search's 62. The second of
    // the three sources segmentation and readings both draw on: usage, then Apple, then the
    // dictionary.
    static func withAppleTokenHint(_ probabilities: [Double], in text: String) -> [Double] {
        let characters = Array(text)
        // Character index for each UTF-16 offset at a character start.
        var characterIndexByUTF16: [Int: Int] = [:]
        var offset = 0
        for (index, character) in characters.enumerated() {
            characterIndexByUTF16[offset] = index
            offset += String(character).utf16.count
        }
        characterIndexByUTF16[offset] = characters.count
        var adjusted = probabilities
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, CFStringGetLength(cf)), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let start = characterIndexByUTF16[range.location], let end = characterIndexByUTF16[range.location + range.length], end - start > 1 {
                for gap in (start + 1)..<end where gap - 1 < adjusted.count {
                    adjusted[gap - 1] *= appleTokenCutFactor
                }
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return adjusted
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
