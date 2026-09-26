import Foundation

// Enumerates the LLM providers song breakdowns can run on.
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
    // The remote-provider pick song breakdowns use.
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

    // The one model each provider uses, chosen by a one-shot seven-model song-breakdown
    // comparison on the same song (2026-09-23). gpt-5.6-luna got every sung reading right at
    // ~0.6¢ a breakdown; gpt-4.1-mini, gpt-5-mini and gpt-4o-mini misread 5–7 of 34 lines and
    // claude-haiku-4-5 ~17. Sonnet 5 stays for Claude (Opus costs ~2.5× more); it needs the
    // reasoning cap in ClaudeRequestParameters or it spends the whole budget thinking.
    static let defaultClaudeModel = "claude-sonnet-5"
    static let defaultOpenAIModel = "gpt-5.6-luna"

    static var defaultProvider: String { LLMProvider.none.rawValue }

    // Claude is a debug-build-only provider: in a one-shot breakdown comparison (2026-09-23) it
    // cost ~8× gpt-5.6-luna without doing better, so release builds (TestFlight / App Store,
    // archived Release by scripts/distribute.sh) don't offer it and treat a stored Claude pick
    // as no provider.
    static var isClaudeAvailable: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // The provider picked in Settings: the REMOTE model (OpenAI / Claude), or none. Apple
    // Intelligence is not a choice here — Cloud / Cloud Pro need the Private Cloud Compute
    // entitlement this app lacks (calling without it SIGTRAPs inside FoundationModels, confirmed on-device
    // 2026-09-10 and -13) — so any stored Apple value reads as none.
    static func remoteProvider() -> LLMProvider {
        let raw = UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
        let provider = LLMProvider(rawValue: raw) ?? .none
        if provider.isAppleIntelligence { return .none }
        if provider == .claude, isClaudeAvailable == false { return .none }
        return provider
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

    // The Claude model every Claude request uses.
    static func claudeModel() -> String {
        defaultClaudeModel
    }

    // The OpenAI model every OpenAI request uses.
    static func openAIModel() -> String {
        defaultOpenAIModel
    }

    // True when a request goes to a paid remote provider (OpenAI / Claude) and is billed to the
    // user's API key — AI on, not the developer stub. Such requests are confirmed before they run.
    static func isPaid() -> Bool {
        guard isEnabled() else { return false }
        switch remoteProvider() {
        case .openAI, .claude: return true
        case .none, .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro: return false
        }
    }

    // Returns true when useLLM is on and the remote provider has a key, or when useLLM is off
    // and a stub is set — i.e. a breakdown request has somewhere to go.
    static func isConfigured() -> Bool {
        if isEnabled() {
            return apiKey(for: remoteProvider()) != nil
        } else {
            let stub = UserDefaults.standard.string(forKey: stubResponseKey) ?? ""
            return stub.isEmpty == false
        }
    }
}
