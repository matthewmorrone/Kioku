import Foundation

// Configures node-cost weighting for Viterbi path scoring.
struct SegmenterScoring {
    let baseCost: Int
    let lengthReward: Int
    let singleCharacterPenalty: Int
    let deinflectionPenalty: Int
    let dictionaryBonus: Int
    let unknownSegmentPenalty: Int
    let posGoodTransitionBonus: Int
    let posBadTransitionPenalty: Int

    static let `default` = SegmenterScoring(
        baseCost: 10,
        lengthReward: 3,
        singleCharacterPenalty: 3,
        deinflectionPenalty: 2,
        dictionaryBonus: 6,
        unknownSegmentPenalty: 40,
        posGoodTransitionBonus: -50,
        posBadTransitionPenalty: 150
    )
}
