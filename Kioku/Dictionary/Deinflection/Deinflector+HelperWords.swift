import Foundation

// Helper words the deinflection rules glue onto their neighbour — the いく of 飛び込んでいく, the くれる
// of 来てくれる, the すぎる of 食べすぎる. The rules keep such a phrase one lattice edge so path
// selection sees it whole; which rules do this, and where the helper starts, is data
// (DeinflectionRule.helper), so this only reads the rules and walks a surface's chosen chain.
nonisolated extension Deinflector {
    // Key for a rule's transition in helperByTransition. No two rules share kanaIn and kanaOut
    // while disagreeing about their helper.
    static func transitionKey(_ kanaIn: String, _ kanaOut: String) -> String {
        kanaIn + "\u{1F}" + kanaOut
    }

    // Builds helperByTransition from the loaded rules.
    static func helperIndex(_ rules: [DeinflectionRule]) -> [String: String] {
        var index: [String: String] = [:]
        for rule in rules {
            if let helper = rule.helper { index[transitionKey(rule.kanaIn, rule.kanaOut)] = helper }
        }
        return index
    }

    // Character offsets in `surface` where a helper word begins, following the chain that reaches
    // `lemma` (飛び込んでいった → [5]: past いった→いく, then でいく→で with helper いく). Each
    // transition rewrites the end of the string, so the text before a helper is still the surface's
    // own prefix — checked, and an offset is skipped when an outer rewrite reached into it.
    func helperWordOffsets(in surface: String, lemma: String) -> [Int] {
        guard helperByTransition.isEmpty == false,
              let transitions = bestTransitions(for: surface, targetLemma: lemma) else { return [] }
        var offsets = Set<Int>()
        var current = surface
        for transition in transitions {
            if let helper = helperByTransition[Self.transitionKey(transition.kanaIn, transition.kanaOut)] {
                let offset = current.count - helper.count
                if offset > 0, offset < surface.count, surface.hasPrefix(current.prefix(offset)) {
                    offsets.insert(offset)
                }
            }
            current = String(current.dropLast(transition.kanaIn.count)) + transition.kanaOut
        }
        return offsets.sorted()
    }
}
