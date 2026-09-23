import Foundation

// The models Settings → AI offers per provider, with list prices checked against each
// provider's pricing page on 2026-09-23 (OpenAI: developers.openai.com/api/docs/pricing;
// Anthropic: its published per-model API rates). Prices change — update them here when they do.
// Ordered most to least capable within each provider.
nonisolated enum LLMModelCatalog {
    static let openAI: [LLMModelOption] = [
        LLMModelOption(id: "gpt-5.6-sol", inputPerMillion: 4.00, outputPerMillion: 20.00),
        LLMModelOption(id: "gpt-5.6-terra", inputPerMillion: 2.00, outputPerMillion: 12.00),
        LLMModelOption(id: "gpt-5.6-luna", inputPerMillion: 0.20, outputPerMillion: 1.20),
        LLMModelOption(id: "gpt-5", inputPerMillion: 1.25, outputPerMillion: 10.00),
        LLMModelOption(id: "gpt-5-mini", inputPerMillion: 0.25, outputPerMillion: 2.00),
        LLMModelOption(id: "gpt-4.1", inputPerMillion: 2.00, outputPerMillion: 8.00),
        LLMModelOption(id: "gpt-4.1-mini", inputPerMillion: 0.40, outputPerMillion: 1.60),
        LLMModelOption(id: "gpt-4o", inputPerMillion: 2.50, outputPerMillion: 10.00),
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

    // The picker row's price, input then output per million tokens: "$0.25 / $2".
    static func priceLabel(for option: LLMModelOption) -> String {
        "\(dollars(option.inputPerMillion)) / \(dollars(option.outputPerMillion))"
    }

    // A dollar amount with cents only when there are any: $2, $2.50, $0.15.
    private static func dollars(_ amount: Double) -> String {
        amount == amount.rounded() ? "$\(Int(amount))" : String(format: "$%.2f", amount)
    }
}
