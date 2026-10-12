import Foundation

// Everything the Deinflector loads: the rules by group (the group names the form on the lookup sheet),
// the godan verbs that look ichidan, and the grammar steps that are never a dictionary form.
nonisolated struct DeinflectionRuleSet {
    let groupedRules: [String: [DeinflectionRule]]
    // Every rule with its group, in the dictionary's order (deinflection_rules.id). The generator
    // writes modern groups before classicalForms, and the deinflector keeps this order between rules of
    // equal length, so a modern reading reaches each state first.
    let orderedRules: [(label: String, rule: DeinflectionRule)]
    let nonIchidanRuVerbs: Set<String>
    let intermediateForms: Set<String>
}
