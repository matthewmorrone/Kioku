import Foundation

// Maps the deinflector's grouped-rule chain labels (the camelCase group keys from
// deinflection.json, e.g. "teForms", "politeForms") to a short human-readable description of the
// grammatical form, for display beside the dictionary lemma in the lookup header. Internal
// stem-recovery steps are omitted — they are mechanical backtracking, not user-facing forms.
enum InflectionFormNames {
    // Display name per deinflection group label. Labels absent here (the *RecoveryForms internals)
    // are intentionally dropped from the user-facing description.
    private static let displayNames: [String: String] = [
        "teForms": "te-form",
        "pastForms": "past",
        "progressiveForms": "progressive",
        "desireForms": "desiderative",
        "politeForms": "polite",
        "passivePotentialForms": "passive / potential",
        "potentialForms": "potential",
        "imperativeForms": "imperative",
        "irregularForms": "irregular",
        "adjectiveForms": "adjectival",
        "conditionalForms": "conditional",
        "contractionForms": "contraction",
        "benefactiveForms": "benefactive",
        "auxiliaryForms": "auxiliary",
        "nounSuffixForms": "noun suffix",
        "passiveNegativeForms": "passive negative",
        "passiveTeForms": "passive te-form",
        "literaryNegativeForms": "literary negative",
        "passiveNegativeTeForms": "passive negative te-form",
    ]

    // Joins the mapped, user-facing labels in chain order with " · ". Returns "" when the chain
    // has no displayable (non-internal) forms, so callers fall back to showing the lemma alone.
    static func describe(_ chain: [String]) -> String {
        chain.compactMap { displayNames[$0] }.joined(separator: " · ")
    }
}
