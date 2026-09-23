import Foundation

// The models Settings → AI offers per provider, with list prices checked against each
// provider's pricing page on 2026-09-23 (OpenAI: developers.openai.com/api/docs/pricing;
// Anthropic: its published per-model API rates). Prices change — update them here when they do.
// Ordered most to least capable within each provider.
nonisolated enum LLMModelCatalog {
    // Only models under a cent per typical breakdown (see breakdownCostCents) are offered.
    static let openAI: [LLMModelOption] = [
        LLMModelOption(id: "gpt-5.6-luna", inputPerMillion: 0.20, outputPerMillion: 1.20),
        LLMModelOption(id: "gpt-5-mini", inputPerMillion: 0.25, outputPerMillion: 2.00),
        LLMModelOption(id: "gpt-4.1-mini", inputPerMillion: 0.40, outputPerMillion: 1.60),
        LLMModelOption(id: "gpt-4o-mini", inputPerMillion: 0.15, outputPerMillion: 0.60),
    ]

    static let claude: [LLMModelOption] = [
        LLMModelOption(id: "claude-opus-5", inputPerMillion: 5.00, outputPerMillion: 25.00),
        LLMModelOption(id: "claude-sonnet-5", inputPerMillion: 2.00, outputPerMillion: 10.00),
        LLMModelOption(id: "claude-haiku-4-5", inputPerMillion: 1.00, outputPerMillion: 5.00),
    ]

    // The models to offer for a provider; empty for providers with no model choice.
    static func options(for provider: LLMProvider) -> [LLMModelOption] {
        switch provider {
        case .openAI: return openAI
        case .claude: return claude
        case .none, .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro: return []
        }
    }

    // A typical song breakdown's size, measured from saved breakdowns (2026-09-23): the ~2,100
    // token instructions plus the lyrics in, the line-by-line breakdown out. A per-million price
    // reads like a per-use price at a glance, so the picker shows what one breakdown costs.
    static let typicalBreakdownInputTokens = 2_700
    static let typicalBreakdownOutputTokens = 3_000

    // The estimated cost of one typical breakdown on this model, in US cents. Excludes caching
    // discounts and a reasoning model's hidden reasoning tokens.
    static func breakdownCostCents(for option: LLMModelOption) -> Double {
        let dollars = Double(typicalBreakdownInputTokens) * option.inputPerMillion / 1_000_000
            + Double(typicalBreakdownOutputTokens) * option.outputPerMillion / 1_000_000
        return dollars * 100
    }

    // The picker row's cost per typical breakdown: "~0.4¢" under a cent, whole cents above ("~4¢").
    static func costLabel(for option: LLMModelOption) -> String {
        let cents = breakdownCostCents(for: option)
        let amount = cents < 1 ? String(format: "%.1f", cents) : String(Int(cents.rounded()))
        return "~\(amount)¢"
    }
}
