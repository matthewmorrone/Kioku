import Foundation

// One model offered in Settings → AI's Model picker: the id sent to the provider and its list
// price in US dollars per million tokens (standard tier, no caching or batch discounts).
nonisolated struct LLMModelOption: Equatable, Identifiable {
    let id: String
    let inputPerMillion: Double
    let outputPerMillion: Double
}
