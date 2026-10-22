import Foundation

// The lookup sheet's use of ContextualClassChoice: among words that share a spelling, the one the
// neighbouring segments point to (a noun sits before a particle, a verb stem before a verb ending),
// else, for a form that is both a verb and another verb's potential, PotentialChoice.
nonisolated extension Lexicon {
    // The candidate whose word class fits the neighbours best, or nil when context does not decide.
    // A candidate's class is the union of its senses' parts of speech, as the segmenter classes it.
    static func contextuallyPreferredCandidate(
        among candidates: [LookupCandidate],
        surface: String,
        neighbours: ContextualClassChoice.Neighbours,
        table: SegmenterTransitionTable,
        margin: Int = ContextualClassChoice.margin
    ) -> LookupCandidate? {
        ContextualClassChoice.best(
            among: candidates,
            surface: surface,
            partOfSpeech: { $0.entry.senses.reduce(UInt64(0)) { $0 | PartOfSpeech.bits(from: $1.pos) } },
            neighbours: neighbours,
            table: table,
            margin: margin
        ) ?? PotentialChoice.preferred(among: candidates, surface: surface, previousSurface: neighbours.previous?.surface)
    }
}
