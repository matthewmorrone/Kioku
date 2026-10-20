import Foundation

// Chooses among readings of one spelling by the words around it — the reusable core of every
// "which one is it here?" decision that has a part of speech per option: a verb's stem or a noun
// (怒り), a particle or a noun (で, に), an adverb or an adjective. Each option is classed as the
// segmenter classes a word (TransitionClass), and the class that is cheapest after the previous
// segment and before the next, by the dictionary's transition table, wins.
//
// Nothing here knows what the options are: a caller supplies them and a function from an option to
// its POS bits, and gets one back or nil. The lookup sheet's word list uses it through
// Lexicon.contextuallyPreferredCandidate; a reading or sense picker with POS to offer can call it the
// same way. Needs the transition table, so it does nothing when the dictionary has none.
nonisolated enum ContextualClassChoice {
    // The segments either side of the one being decided; nil at the start or end of the text.
    struct Neighbours {
        let previous: LatticeEdge?
        let next: LatticeEdge?
    }

    // How much cheaper, in centi-nats, the best class must be than the next one before it decides.
    // Smaller gaps are context that does not really say, and the choice stays open.
    static let margin = 40

    // The option whose class fits `neighbours` best, or nil when context does not decide: fewer than
    // two options, two options share the best class (two verbs), or the best class is not clearly
    // ahead of the next.
    static func best<Option>(
        among options: [Option],
        surface: String,
        partOfSpeech: (Option) -> UInt64,
        neighbours: Neighbours,
        table: SegmenterTransitionTable,
        margin: Int = ContextualClassChoice.margin
    ) -> Option? {
        guard options.count > 1 else { return nil }
        let before = table.classIDs(for: neighbours.previous)
        let after = table.classIDs(for: neighbours.next)
        // Each option's class as the table names it, and what that class costs here.
        var costByClass: [String: Int] = [:]
        var optionsByClass: [String: [Option]] = [:]
        for option in options {
            let bits = partOfSpeech(option)
            let name = TransitionClass.name(surface: surface, partOfSpeech: bits, lexical: table.lexical)
            let ids = table.classIDs(surface: surface, partOfSpeech: bits)
            costByClass[name] = table.cost(from: before, to: ids) + table.cost(from: ids, to: after)
            optionsByClass[name, default: []].append(option)
        }
        let ranked = costByClass.sorted { $0.value < $1.value }
        guard ranked.count > 1,
              let best = ranked.first,
              optionsByClass[best.key]?.count == 1,
              ranked[1].value - best.value >= margin else { return nil }
        return optionsByClass[best.key]?.first
    }
}
