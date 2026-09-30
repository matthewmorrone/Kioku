import Foundation

// Which grammar a deinflection chain claims its lemma has: the rulesOut of the chain's last rule.
// いった reaches いる only through a godan past rule, so that いる is a godan verb (要る), never the
// ichidan 居る. Read from the loaded rules; nothing here names a word.
nonisolated extension Deinflector {
    // Builds rulesOutByTransition from the loaded rules, keyed like helperByTransition.
    static func rulesOutIndex(
        _ labeledRules: [(label: String, rule: DeinflectionRule)],
        normalizingLabel: (String) -> String
    ) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for labeled in labeledRules {
            let key = helperKey(label: normalizingLabel(labeled.label), kanaIn: labeled.rule.kanaIn, kanaOut: labeled.rule.kanaOut)
            index[key, default: []].formUnion(labeled.rule.rulesOut)
        }
        return index
    }

    // The grammars (v1, v5, vk, vs, adj-i, …) the chains to `targetLemma` end on. Empty when the
    // lemma was reached by no rule — the surface itself.
    func endingGrammars(from pathsByLemma: DeinflectionPathMap, targetLemma: String) -> Set<String> {
        var grammars = Set<String>()
        for path in pathsByLemma[targetLemma] ?? [] {
            guard let last = path.transitions.last else { continue }
            grammars.formUnion(rulesOutByTransition[Self.helperKey(label: last.label, kanaIn: last.kanaIn, kanaOut: last.kanaOut)] ?? [])
        }
        return grammars
    }
}
