import Foundation

// Enumerates the supported LLM providers for segmentation correction.
// None means no key is configured and the feature is unavailable.
enum LLMProvider: String, CaseIterable {
    case none = ""
    case openAI = "openai"
    case claude = "claude"

    // Human-readable label shown in the provider picker.
    var displayName: String {
        switch self {
        case .none: return "None"
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        }
    }
}

// Centralizes storage keys and defaults for LLM provider configuration.
// Keys use the kioku.llm prefix to avoid collisions with other app settings.
enum LLMSettings {
    static let providerKey = "kioku.llm.provider"
    static let openAIKeyStorageKey = "kioku.llm.openaiKey"
    static let claudeKeyStorageKey = "kioku.llm.claudeKey"

    static let defaultProvider = LLMProvider.none.rawValue

    // Returns the active provider from UserDefaults, defaulting to none if unrecognized.
    static func activeProvider() -> LLMProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
        return LLMProvider(rawValue: raw) ?? .none
    }

    // Returns the API key for the currently configured provider, or nil if not set.
    static func activeAPIKey() -> String? {
        switch activeProvider() {
        case .none:
            return nil
        case .openAI:
            let key = UserDefaults.standard.string(forKey: openAIKeyStorageKey) ?? ""
            return key.isEmpty ? nil : key
        case .claude:
            let key = UserDefaults.standard.string(forKey: claudeKeyStorageKey) ?? ""
            return key.isEmpty ? nil : key
        }
    }

    // Returns true when a provider is selected and its key is non-empty.
    // Used to show or enable the correction button in ReadView.
    static func isConfigured() -> Bool {
        activeAPIKey() != nil
    }
}
