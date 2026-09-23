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
    // The one shared remote-provider pick, used for both Correction and Breakdown.
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
    // AI is on unless the developer stub mode (Advanced → Diagnostics) turned it off.
    static func isEnabled() -> Bool {
        UserDefaults.standard.object(forKey: useLLMKey) == nil || UserDefaults.standard.bool(forKey: useLLMKey)
    }
    // Compact-format stub used when useLLM is false. Parsed by the same pipeline as real responses.
    static let stubResponseKey = "kioku.llm.stubResponse"
    // Sampling temperature sent to the LLM. Lower = more deterministic; range 0.0–1.0.
    static let temperatureKey = "kioku.llm.temperature"
    static let defaultTemperature: Double = 0.4

    // The one model each provider uses, chosen by a one-shot seven-model song-breakdown
    // comparison on the same song (2026-09-23). gpt-5.6-luna got every sung reading right at
    // ~0.6¢ a breakdown; gpt-4.1-mini, gpt-5-mini and gpt-4o-mini misread 5–7 of 34 lines and
    // claude-haiku-4-5 ~17. Sonnet 5 stays for Claude (Opus costs ~2.5× more); it needs the
    // reasoning cap in ClaudeRequestParameters or it spends the whole budget thinking.
    static let defaultClaudeModel = "claude-sonnet-5"
    static let defaultOpenAIModel = "gpt-5.6-luna"

    // When true, the LLM request includes a web-search tool the model can use to
    // look up canonical lyrics (Uta-Net / J-Lyric / Genius / Niconico Kashi)
    // and ground gikun/ateji readings that don't follow morphological rules.
    // Apple Intelligence is offline-only and ignores this setting. Defaults to
    // true because the cost is bounded by the model's own judgment about when
    // to invoke the tool, and song lyrics — the common case for Kioku — depend
    // heavily on contextual readings JMdict doesn't carry.
    static let useWebSearchKey = "kioku.llm.useWebSearch"
    // Whether on-device Apple Intelligence should be usable at all when the device has it.
    // Off means correctionProvider() never resolves to it, even if available — Correction
    // falls straight through to the shared remote provider (or none).
    static let appleIntelligenceEnabledKey = "kioku.llm.appleIntelligenceEnabled"
    // True unless the user explicitly turned the toggle off.
    static func isAppleIntelligenceEnabled() -> Bool {
        UserDefaults.standard.object(forKey: appleIntelligenceEnabledKey) == nil
            || UserDefaults.standard.bool(forKey: appleIntelligenceEnabledKey)
    }
    // For OpenAI: when web search is enabled, this model is used in place of the
    // user's configured model because web_search is a model-level feature in the
    // Chat Completions API rather than a separately-passable tool. The user's
    // configured model is restored when web search is off. gpt-4o-search-preview
    // and gpt-4o-mini-search-preview were retired 2026-07-23; gpt-5-search-api is
    // their Chat Completions replacement.
    static let openAISearchModel = "gpt-5-search-api"

    static var defaultProvider: String { LLMProvider.none.rawValue }

    // The provider picked in Settings: the REMOTE model (OpenAI / Claude), or none. On-device
    // Apple Intelligence is not a choice here but a capability the app uses on its own (see
    // correctionProvider), and Cloud / Cloud Pro need the Private Cloud Compute entitlement this
    // app lacks (calling without it SIGTRAPs inside FoundationModels, confirmed on-device
    // 2026-09-10 and -13) — so any stored Apple value reads as none.
    static func remoteProvider() -> LLMProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
        let provider = LLMProvider(rawValue: raw) ?? .none
        return provider.isAppleIntelligence ? .none : provider
    }

    // The provider correction runs on: on-device Apple Intelligence when it's available and the
    // toggle hasn't turned it off, else the shared remote provider if it has a key, else none.
    static func correctionProvider() -> LLMProvider {
        if AppleIntelligenceAvailability.isAvailable, isAppleIntelligenceEnabled() { return .appleIntelligence }
        let remote = remoteProvider()
        return apiKey(for: remote) != nil ? remote : .none
    }

    // The provider song breakdowns run on: always the shared remote one (on-device can't do them).
    static func breakdownProvider() -> LLMProvider { remoteProvider() }

    // The stored API key for a remote provider (Keychain), nil for none / Apple variants.
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

    // Returns the API key for the current correction provider, or nil if not set.
    static func activeAPIKey() -> String? {
        apiKey(for: correctionProvider())
    }

    // The Claude model every Claude request uses.
    static func claudeModel() -> String {
        defaultClaudeModel
    }

    // The OpenAI model every OpenAI request uses (the web-search path swaps in its own model).
    static func openAIModel() -> String {
        defaultOpenAIModel
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

    // Returns true when useLLM is on and the correction provider is usable (Apple
    // Intelligence available on-device or via Private Cloud Compute, or a remote
    // provider with a key), or when useLLM is off and a stub is set.
    static func isConfigured() -> Bool {
        if isEnabled() {
            let provider = correctionProvider()
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
