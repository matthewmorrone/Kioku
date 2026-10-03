import Foundation

// Everything the Deinflector loads: the rules by group (the group names the form on the lookup sheet),
// the godan verbs that look ichidan, and the grammar steps that are never a dictionary form.
nonisolated struct DeinflectionRuleSet {
    let groupedRules: [String: [DeinflectionRule]]
    let nonIchidanRuVerbs: Set<String>
    let intermediateForms: Set<String>
}
