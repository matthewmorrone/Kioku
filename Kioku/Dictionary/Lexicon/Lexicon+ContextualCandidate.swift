import Foundation

// Picks between words that share a spelling by the words around it, for a form that is both a
// verb's stem and a noun (怒り, 話し, 動き): a noun sits before a particle, a stem before a verb
// ending. The decision is the segmenter's own transition table — how likely a class is after the
// previous word and before the next, counted from gold sentences — applied to each candidate's class
// rather than to the surface's merged one (TransitionClass tags a spelling by the union of its
// entries, so the segmenter itself never decides this).
nonisolated extension Lexicon {
    // How much cheaper, in centi-nats, the best class must be than the next one before it decides.
    // Smaller gaps are context that does not really say, and the form stays unpicked.
    private static let contextualCandidateMargin = 40

    // The candidate whose class fits `previous` and `next` best, or nil when context does not decide:
    // two candidates share the best class (two verbs), or the best class is not clearly ahead.
    static func contextuallyPreferredCandidate(
        among candidates: [LookupCandidate],
        surface: String,
        previous: LatticeEdge?,
        next: LatticeEdge?,
        table: SegmenterTransitionTable
    ) -> LookupCandidate? {
        guard candidates.count > 1 else { return nil }
        let before = table.classIDs(for: previous)
        let after = table.classIDs(for: next)
        // Each candidate's class as the table names it, and what that class costs here.
        var costByClass: [String: Int] = [:]
        var candidatesByClass: [String: [LookupCandidate]] = [:]
        for candidate in candidates {
            let bits = candidate.entry.senses.reduce(UInt64(0)) { $0 | PartOfSpeech.bits(from: $1.pos) }
            let name = TransitionClass.name(surface: surface, partOfSpeech: bits, lexical: table.lexical)
            let ids = table.classIDs(surface: surface, partOfSpeech: bits)
            costByClass[name] = table.cost(from: before, to: ids) + table.cost(from: ids, to: after)
            candidatesByClass[name, default: []].append(candidate)
        }
        let ranked = costByClass.sorted { $0.value < $1.value }
        guard ranked.count > 1,
              let best = ranked.first,
              candidatesByClass[best.key]?.count == 1,
              ranked[1].value - best.value >= contextualCandidateMargin else { return nil }
        return candidatesByClass[best.key]?.first
    }
}
