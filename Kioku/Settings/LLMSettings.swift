import Foundation

// Enumerates the supported LLM providers for segmentation correction.
// None means no key is configured and the feature is unavailable.
enum LLMProvider: String, CaseIterable {
    case none = ""
    case appleIntelligence = "apple"
    // Apple Intelligence's server-side model (Private Cloud Compute, iOS 27+): same on-device
    // privacy story, no API key, but a much larger context window and a "reasoning" mode. Cloud
    // Pro asks for the deeper (slower, higher-quality) reasoning level; Cloud asks for the
    // default. Only usable for song breakdown / merged breakdown today — see
    // AppleIntelligenceCloudClient and SongBreakdownError.appleIntelligenceCloudUnavailable.
    case appleIntelligenceCloud = "apple_cloud"
    case appleIntelligenceCloudPro = "apple_cloud_pro"
    case openAI = "openai"
    case claude = "claude"

    // Human-readable label shown in the provider picker.
    var displayName: String {
        switch self {
        case .none: return "None"
        case .appleIntelligence: return "Apple Intelligence"
        case .appleIntelligenceCloud: return "Apple Intelligence (Cloud)"
        case .appleIntelligenceCloudPro: return "Apple Intelligence (Cloud Pro)"
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        }
    }

    // True when the provider runs entirely on-device and needs no API key. The cloud Apple
    // Intelligence variants also need no key, but do leave the device (Private Cloud Compute) —
    // callers that mean "no network at all" should check this, not just "no key needed".
    var isOnDevice: Bool {
        self == .appleIntelligence
    }

    // True for any Apple Intelligence variant (on-device or cloud) — none of them take an API
    // key, unlike OpenAI/Claude.
    var isAppleIntelligence: Bool {
        self == .appleIntelligence || self == .appleIntelligenceCloud || self == .appleIntelligenceCloudPro
    }
}

// Centralizes storage keys and defaults for LLM provider configuration.
// Keys use the kioku.llm prefix to avoid collisions with other app settings.
enum LLMSettings {
    static let providerKey = "kioku.llm.provider"
    // API keys live in the Keychain. These constants double as the Keychain account
    // names and the legacy UserDefaults keys that pre-Keychain installs migrate from.
    static let openAIKeyStorageKey = "kioku.llm.openaiKey"
    static let claudeKeyStorageKey = "kioku.llm.claudeKey"
    // Non-secret counter bumped whenever a key is edited. Views that previously
    // observed the key strings via @AppStorage observe this instead, so key-presence
    // UI stays reactive without the secrets living in UserDefaults.
    static let keysRevisionKey = "kioku.llm.keysRevision"
    // When false (default), the stub response is used instead of a real API call.
    static let useLLMKey = "kioku.llm.useLLM"
    // Compact-format stub used when useLLM is false. Parsed by the same pipeline as real responses.
    static let stubResponseKey = "kioku.llm.stubResponse"
    // Sampling temperature sent to the LLM. Lower = more deterministic; range 0.0–1.0.
    static let temperatureKey = "kioku.llm.temperature"
    static let defaultTemperature: Double = 0.4

    // Model identifiers sent to each provider. Configurable so the model can be changed
    // without a rebuild. Claude defaults to the current-generation Sonnet — strong at Japanese
    // and cheaper than both Opus and the prior Sonnet generation ($2/$10 per Mtok vs Opus's
    // $5/$25 and Sonnet 4.6's $3/$15). OpenAI defaults to gpt-4o.
    static let claudeModelKey = "kioku.llm.claudeModel"
    static let defaultClaudeModel = "claude-sonnet-5"
    static let openAIModelKey = "kioku.llm.openaiModel"
    static let defaultOpenAIModel = "gpt-4o"

    // When true, the LLM request includes a web-search tool the model can use to
    // look up canonical lyrics (Uta-Net / J-Lyric / Genius / Niconico Kashi)
    // and ground gikun/ateji readings that don't follow morphological rules.
    // Apple Intelligence is offline-only and ignores this setting. Defaults to
    // true because the cost is bounded by the model's own judgment about when
    // to invoke the tool, and song lyrics — the common case for Kioku — depend
    // heavily on contextual readings JMdict doesn't carry.
    static let useWebSearchKey = "kioku.llm.useWebSearch"
    // For OpenAI: when web search is enabled, this model is used in place of the
    // user's configured model because web_search is a model-level feature in the
    // Chat Completions API rather than a separately-passable tool. The user's
    // configured model is restored when web search is off. gpt-4o-search-preview
    // and gpt-4o-mini-search-preview were retired 2026-07-23; gpt-5-search-api is
    // their Chat Completions replacement.
    static let openAISearchModel = "gpt-5-search-api"

    // Computed so a fresh install on an Apple-Intelligence-capable device picks
    // the on-device model by default instead of starting at "None". Existing
    // installs keep their stored value (@AppStorage only consults the default
    // when no value exists yet).
    static var defaultProvider: String {
        AppleIntelligenceAvailability.isAvailable
            ? LLMProvider.appleIntelligence.rawValue
            : LLMProvider.none.rawValue
    }

    // Returns the active provider from UserDefaults, defaulting to none if unrecognized.
    static func activeProvider() -> LLMProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
        return LLMProvider(rawValue: raw) ?? .none
    }

    // Returns the API key for the given provider from the Keychain, or nil if not set.
    // No Apple Intelligence variant (on-device or cloud) takes an API key — always returns nil.
    static func apiKey(for provider: LLMProvider) -> String? {
        switch provider {
        case .none, .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro:
            return nil
        case .openAI:
            return KeychainStore.string(forKey: openAIKeyStorageKey, migratingFromUserDefaultsKey: openAIKeyStorageKey)
        case .claude:
            return KeychainStore.string(forKey: claudeKeyStorageKey, migratingFromUserDefaultsKey: claudeKeyStorageKey)
        }
    }

    // Stores or clears a provider's API key in the Keychain. No-op for Apple Intelligence providers.
    static func setAPIKey(_ key: String?, for provider: LLMProvider) {
        switch provider {
        case .none, .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro:
            break
        case .openAI:
            KeychainStore.setString(key, forKey: openAIKeyStorageKey)
        case .claude:
            KeychainStore.setString(key, forKey: claudeKeyStorageKey)
        }
    }

    // Returns the API key for the currently configured provider, or nil if not set.
    static func activeAPIKey() -> String? {
        apiKey(for: activeProvider())
    }

    // Returns the configured Claude model id, defaulting to Sonnet 5 when unset or blank.
    static func claudeModel() -> String {
        let stored = UserDefaults.standard.string(forKey: claudeModelKey) ?? ""
        return stored.isEmpty ? defaultClaudeModel : stored
    }

    // Returns the configured OpenAI model id, defaulting to gpt-4o when unset or blank.
    static func openAIModel() -> String {
        let stored = UserDefaults.standard.string(forKey: openAIModelKey) ?? ""
        return stored.isEmpty ? defaultOpenAIModel : stored
    }

    // True when the user has opted into the LLM using a web-search tool to
    // verify readings against canonical lyric sources. Defaults to true on a
    // fresh install — the toggle exists so users can opt out (cost or privacy
    // concerns) but the common case for songs benefits from it.
    static func isWebSearchEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: useWebSearchKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: useWebSearchKey)
    }

    // Returns true when useLLM is on and the active provider is usable (Apple
    // Intelligence available on-device or via Private Cloud Compute, or a remote
    // provider with a key), or when useLLM is off and a stub is set.
    static func isConfigured() -> Bool {
        if UserDefaults.standard.bool(forKey: useLLMKey) {
            let provider = activeProvider()
            switch provider {
            case .appleIntelligence:
                return AppleIntelligenceAvailability.isAvailable
            case .appleIntelligenceCloud, .appleIntelligenceCloudPro:
                return AppleIntelligenceCloudAvailability.isAvailable
            case .none, .openAI, .claude:
                break
            }
            return activeAPIKey() != nil
        } else {
            let stub = UserDefaults.standard.string(forKey: stubResponseKey) ?? ""
            return stub.isEmpty == false
        }
    }
}
