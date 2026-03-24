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
    // When false (default), the stub response is used instead of a real API call.
    static let useLLMKey = "kioku.llm.useLLM"
    // Compact-format stub used when useLLM is false. Parsed by the same pipeline as real responses.
    static let stubResponseKey = "kioku.llm.stubResponse"
    // Sampling temperature sent to the LLM. Lower = more deterministic; range 0.0–1.0.
    static let temperatureKey = "kioku.llm.temperature"
    static let defaultTemperature: Double = 0.4

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

    // Returns true when useLLM is on and an API key is set, or when useLLM is off and a stub is set.
    static func isConfigured() -> Bool {
        if UserDefaults.standard.bool(forKey: useLLMKey) {
            return activeAPIKey() != nil
        } else {
            let stub = UserDefaults.standard.string(forKey: stubResponseKey) ?? ""
            return stub.isEmpty == false
        }
    }
}
