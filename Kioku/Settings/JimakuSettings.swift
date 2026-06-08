import Foundation

// Centralizes storage for the Jimaku API key (Feature B). Mirrors ParticleSettings'/LLMSettings'
// nonisolated-enum-of-static-keys pattern so SettingsView and the search screen can read the same
// UserDefaults key. `nonisolated` because JimakuProvider (a free-standing actor) reads it from
// outside the project's MainActor-default isolation domain.
//
// Jimaku needs exactly ONE credential: an API key generated in the user's jimaku.cc account
// settings, sent as the `Authorization` header on every request. No login, no token exchange, no
// per-app consumer registration — the whole reason we swapped away from OpenSubtitles.
nonisolated enum JimakuSettings {
    static let apiKeyStorageKey = "kioku.jimaku.apiKey"
    static let apiBaseURL = "https://jimaku.cc/api"

    // Returns the configured API key, or nil when the user hasn't entered one.
    static func apiKey() -> String? {
        let value = UserDefaults.standard.string(forKey: apiKeyStorageKey) ?? ""
        return value.isEmpty ? nil : value
    }

    // Both searching and downloading require only the API key.
    static func isConfigured() -> Bool {
        apiKey() != nil
    }
}
