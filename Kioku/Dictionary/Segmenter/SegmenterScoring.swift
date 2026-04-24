import Foundation

// Configures node-cost weighting for Viterbi path scoring.
nonisolated struct SegmenterScoring {
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

    // MARK: - Viterbi scoring constants (not yet wired into the active segmentation path)

    static let viterbiDictionaryBonus = -3
    static let viterbiSingleCharacterPenalty = 3
    static let viterbiNonFunctionalSingleCharacterPenalty = 12
    static let viterbiUnknownPenalty = 6
    static let viterbiLengthRewardPerCharacter = -6
    static let viterbiVerbBonus = -3

    static let viterbiParticleParticlePenalty = 10
    static let viterbiPrefixParticlePenalty = 8
    static let viterbiCounterParticlePenalty = 6
    static let viterbiNounNounPenalty = 3
    static let viterbiNounParticleReward = -4
    static let viterbiAdjParticleReward = -3
    static let viterbiVerbAuxiliaryReward = -4
    static let viterbiVerbParticleReward = -2
    static let viterbiParticleNounReward = -2

    // Calculates edge-local node cost independent of predecessor transitions.
    static func edgeCost(_ edge: LatticeEdge) -> Int {
        var cost = 0

        if edge.isDictionaryMatch {
            cost += viterbiDictionaryBonus
        }

        if edge.surface.count == 1 {
            cost += viterbiSingleCharacterPenalty + 5
            if !PartOfSpeech.isParticle(edge.partOfSpeech)
                && !PartOfSpeech.isAuxiliary(edge.partOfSpeech)
                && !isPunctuationSurface(edge.surface) {
                cost += viterbiNonFunctionalSingleCharacterPenalty
            }
        }

        if !edge.isDictionaryMatch {
            cost += viterbiUnknownPenalty
        }

        cost += edge.surface.count * viterbiLengthRewardPerCharacter

        if PartOfSpeech.isVerb(edge.partOfSpeech) {
            cost += viterbiVerbBonus
        }

        return cost
    }

    // Detects punctuation-only single-character surfaces so they avoid strong lexical penalties.
    private static func isPunctuationSurface(_ surface: String) -> Bool {
        guard surface.count == 1 else { return false }
        for scalar in surface.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            return false
        }
        return true
    }

    // Scores a POS transition cost between adjacent edges using lightweight heuristics.
    static func transitionCost(prev: UInt64, next: UInt64) -> Int {
        if prev == 0 || next == 0 { return 0 }
        if PartOfSpeech.isParticle(prev) && PartOfSpeech.isParticle(next) { return viterbiParticleParticlePenalty }
        if PartOfSpeech.isPrefix(prev)   && PartOfSpeech.isParticle(next) { return viterbiPrefixParticlePenalty }
        if PartOfSpeech.isCounter(prev)  && PartOfSpeech.isParticle(next) { return viterbiCounterParticlePenalty }
        if PartOfSpeech.isNoun(prev)     && PartOfSpeech.isNoun(next)     { return viterbiNounNounPenalty }
        if PartOfSpeech.isNoun(prev)     && PartOfSpeech.isParticle(next) { return viterbiNounParticleReward }
        if PartOfSpeech.isAdjective(prev) && PartOfSpeech.isParticle(next) { return viterbiAdjParticleReward }
        if PartOfSpeech.isVerb(prev)     && PartOfSpeech.isAuxiliary(next) { return viterbiVerbAuxiliaryReward }
        if PartOfSpeech.isVerb(prev)     && PartOfSpeech.isParticle(next) { return viterbiVerbParticleReward }
        if PartOfSpeech.isParticle(prev) && PartOfSpeech.isNoun(next)     { return viterbiParticleNounReward }
        return 0
    }
}
