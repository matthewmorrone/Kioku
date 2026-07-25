import Foundation

// Persists per-feature enable state for AppLog, keyed off LogFeature. Backs the Settings →
// Debug Logs toggle list (LogSettingsView). Defaults to enabled: the point of AppLog is that a
// raw request/response is there the moment you go looking, with no setup step first — a feature
// only goes quiet once someone explicitly flips it off because it's drowning out the rest.
enum LogFeatureSettings {
    // nonisolated: read from AppLog's nonisolated logging calls, which fire from URLSession
    // delegates, NWConnection callbacks, and other genuinely non-isolated contexts. UserDefaults
    // itself is thread-safe.
    nonisolated private static func key(_ feature: LogFeature) -> String { "log.feature.\(feature.rawValue)" }

    // Reads a feature's toggle, defaulting to enabled when the user has never touched it —
    // distinguishes "never set" from "explicitly set to false" via UserDefaults.object(forKey:).
    nonisolated static func isEnabled(_ feature: LogFeature) -> Bool {
        guard UserDefaults.standard.object(forKey: key(feature)) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key(feature))
    }

    // Persists a feature's toggle, called from the Settings → Debug Logs switch.
    nonisolated static func setEnabled(_ feature: LogFeature, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key(feature))
    }
}
