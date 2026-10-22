import Foundation

// Chooses between a tapped form's own word and the godan potential of another verb that is spelled
// the same: 溶ける is "to melt" and also 溶く "can dissolve". Both stay in the lookup sheet's list;
// this picks the one shown first. The own word is the default — it is the far commoner reading — but
// a potential takes the object it acts on with が or を (絵の具が溶ける, 水を飲める), so a が or を just
// before the form says the transitive verb's potential is meant. Nothing here knows which verbs; the
// candidates carry whether their chain ends in the potential (LookupCandidate.viaPotential).
nonisolated enum PotentialChoice {
    // The own word, or the potential reading when the previous segment is が or を; nil when the
    // candidates are not exactly one own word and potentials of other verbs (so nothing to decide).
    static func preferred(among candidates: [LookupCandidate], surface: String, previousSurface: String?) -> LookupCandidate? {
        let potentials = candidates.filter(\.viaPotential)
        let own = candidates.filter { $0.viaPotential == false && $0.lemma == surface }
        guard own.count == 1, potentials.isEmpty == false, own.count + potentials.count == candidates.count else { return nil }
        if let previousSurface, ["が", "を"].contains(previousSurface), potentials.count == 1 {
            return potentials[0]
        }
        return own[0]
    }
}
