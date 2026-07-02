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
        "negativeForms": "negative",
        "negativePastForms": "negative past",
        "negativeTeForms": "negative te-form",
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

    // Short English gloss of what each form does to the base meaning ("~" = the dictionary verb),
    // so the lookup surfaces the *meaning* of the surfaced form, not just its name. Structural
    // labels with no clean meaning modifier (irregular/adjectival/contraction/auxiliary/noun-suffix)
    // are intentionally absent so they don't clutter the hint.
    private static let effects: [String: String] = [
        "teForms": "~ and… / -ing",
        "pastForms": "did ~ (past)",
        "progressiveForms": "is ~-ing",
        "negativeForms": "not ~ / don't ~",
        "negativePastForms": "didn't ~",
        "negativeTeForms": "without ~-ing",
        "desireForms": "want to ~",
        "politeForms": "(polite)",
        "passivePotentialForms": "can ~ / is ~-ed",
        "potentialForms": "can ~",
        "imperativeForms": "~! (command)",
        "conditionalForms": "if / when ~",
        "benefactiveForms": "~ for someone",
        "passiveNegativeForms": "isn't ~-ed",
        "passiveTeForms": "being ~-ed",
        "literaryNegativeForms": "not ~ (literary)",
        "passiveNegativeTeForms": "not being ~-ed",
    ]

    // A learner hint for the meaning the inflection conveys — e.g. 隠せない → "can't ~". Merges the
    // most common multi-step combinations into one idiomatic phrase, else joins the per-form
    // effects with " · " (a set membership test, so chain order doesn't matter for the merges).
    // Returns "" when no step has a mapped effect, so callers can hide the hint.
    static func meaning(_ chain: [String]) -> String {
        let set = Set(chain)
        if set.isSuperset(of: ["potentialForms", "negativeForms"]) { return "can't ~" }
        if set.isSuperset(of: ["desireForms", "negativeForms"]) { return "don't want to ~" }
        if set.isSuperset(of: ["potentialForms", "pastForms"]) { return "could ~" }
        return chain.compactMap { effects[$0] }.joined(separator: " · ")
    }
}
