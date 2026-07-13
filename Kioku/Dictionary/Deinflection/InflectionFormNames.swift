import Foundation

// Maps the deinflector's grouped-rule chain labels to a short human-readable description of the
// grammatical form, for display beside the dictionary lemma in the lookup header. Internal
// stem-recovery steps are omitted — they are mechanical backtracking, not user-facing forms.
//
// Keys are NOT the raw deinflection.json group names ("teForms", "negativePastForms") — the
// deinflector normalizes each rule's group label before it ever reaches here (Deinflector.
// normalizedRuleLabel: strips the "Forms" suffix, then splits camelCase into lowercase
// space-separated words — "negativePastForms" -> "negative past"). Keying this table by the raw
// group names meant every lookup missed silently: describe(_:)/meaning(_:) always returned "",
// so no word ever showed a grammatical-form caption. Confirmed via a live chain dump for 見てる,
// which reported chain=["progressive"], not chain=["progressiveForms"].
nonisolated enum InflectionFormNames {
    // Display name per normalized chain label. Labels absent here (the internal recovery-step
    // labels: "stem recovery", "passive stem recovery", "desire negative recovery", "compound
    // verb recovery") are intentionally dropped from the user-facing description.
    private static let displayNames: [String: String] = [
        "te": "te-form",
        "past": "past",
        "progressive": "progressive",
        "negative": "negative",
        "negative past": "negative past",
        "negative te": "negative te-form",
        "desire": "desiderative",
        "polite": "polite",
        "passive potential": "passive / potential",
        "potential": "potential",
        "imperative": "imperative",
        "irregular": "irregular",
        "adjective": "adjectival",
        "conditional": "conditional",
        "contraction": "contraction",
        "benefactive": "benefactive",
        "auxiliary": "auxiliary",
        "noun suffix": "noun suffix",
        "passive negative": "passive negative",
        "passive te": "passive te-form",
        "literary negative": "literary negative",
        "passive negative te": "passive negative te-form",
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
        "te": "~ and… / -ing",
        "past": "did ~ (past)",
        "progressive": "is ~-ing",
        "negative": "not ~ / don't ~",
        "negative past": "didn't ~",
        "negative te": "without ~-ing",
        "desire": "want to ~",
        "polite": "(polite)",
        "passive potential": "can ~ / is ~-ed",
        "potential": "can ~",
        "imperative": "~! (command)",
        "conditional": "if / when ~",
        "benefactive": "~ for someone",
        "passive negative": "isn't ~-ed",
        "passive te": "being ~-ed",
        "literary negative": "not ~ (literary)",
        "passive negative te": "not being ~-ed",
    ]

    // A learner hint for the meaning the inflection conveys — e.g. 隠せない → "can't ~". Merges the
    // most common multi-step combinations into one idiomatic phrase, else joins the per-form
    // effects with " · " (a set membership test, so chain order doesn't matter for the merges).
    // Returns "" when no step has a mapped effect, so callers can hide the hint.
    static func meaning(_ chain: [String]) -> String {
        let set = Set(chain)
        if set.isSuperset(of: ["potential", "negative"]) { return "can't ~" }
        if set.isSuperset(of: ["desire", "negative"]) { return "don't want to ~" }
        if set.isSuperset(of: ["potential", "past"]) { return "could ~" }
        return chain.compactMap { effects[$0] }.joined(separator: " · ")
    }
}
