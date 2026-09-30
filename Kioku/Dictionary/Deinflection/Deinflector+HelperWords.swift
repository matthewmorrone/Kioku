import Foundation

// Helper words the deinflection rules fold into their neighbour — the ゆく of 歩いてゆこう, the ながら
// of 抱かれながら, the しまう of 忘れちゃう. Segmentation keeps such a phrase one word; the lookup sheet
// names each folded word beside the lemma so none is hidden. Which rules fold a word, and which
// word, is data (DeinflectionRule.helper); this only reads the rules and walks a chosen chain.
nonisolated extension Deinflector {
    // Key for a rule's transition in helperByTransition: its group plus both kana, the same triple
    // a path's transitions carry.
    static func helperKey(label: String, kanaIn: String, kanaOut: String) -> String {
        label + "\u{1F}" + kanaIn + "\u{1F}" + kanaOut
    }

    // Builds helperByTransition from the loaded rules, keyed by the label a path's transitions carry
    // (normalizedRuleLabel: "auxiliaryForms" → "auxiliary").
    static func helperIndex(
        _ labeledRules: [(label: String, rule: DeinflectionRule)],
        normalizingLabel: (String) -> String
    ) -> [String: String] {
        var index: [String: String] = [:]
        for labeled in labeledRules {
            if let helper = labeled.rule.helper {
                index[helperKey(label: normalizingLabel(labeled.label), kanaIn: labeled.rule.kanaIn, kanaOut: labeled.rule.kanaOut)] = helper
            }
        }
        return index
    }

    // The helper words folded into a surface on its chain to `targetLemma`, in reading order
    // (抱かれながら → ["ながら"], 飛び込んでいっちゃった → ["いく", "しまう"]). Transitions strip the
    // surface from its end inward, so they are collected outermost-first and reversed.
    func helperWords(from pathsByLemma: DeinflectionPathMap, targetLemma: String) -> [String] {
        guard helperByTransition.isEmpty == false,
              let transitions = bestTransitions(from: pathsByLemma, targetLemma: targetLemma) else { return [] }
        var helpers: [String] = []
        for transition in transitions.reversed() {
            let key = Self.helperKey(label: transition.label, kanaIn: transition.kanaIn, kanaOut: transition.kanaOut)
            if let helper = helperByTransition[key], helpers.last != helper {
                helpers.append(helper)
            }
        }
        return helpers
    }
}
