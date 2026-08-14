import Foundation

// Maps the deinflector's grouped-rule chain labels to a short human-readable description of the
// grammatical form, for display beside the dictionary lemma in the lookup header. Internal
// stem-recovery steps are omitted — they are mechanical backtracking, not user-facing forms.
//
// Keys are NOT the raw deinflection.json group names ("teForms", "negativePastForms") — the
// deinflector normalizes each rule's group label before it ever reaches here (Deinflector.
// normalizedRuleLabel: strips the "Forms" suffix, then splits camelCase into lowercase
// space-separated words — "negativePastForms" -> "negative past"). Keying this table by the raw
// group names meant every lookup missed silently: describe(_:) always returned "", so no word
// ever showed a grammatical-form caption. Confirmed via a live chain dump for 見てる,
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
}
