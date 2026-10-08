import Foundation

// "Bool with a default when never set" read for UserDefaults: `bool(forKey:)` alone can't tell
// "never touched" from "explicitly set to false", so any flag that defaults to true (or changed
// its default after shipping) needs the explicit `object(forKey:) != nil` check this centralizes.
// Several settings enums (LogFeatureSettings, AudioSettings, DictionarySettings, LLMSettings)
// repeated this by hand before converging here.
nonisolated enum UserDefaultsBool {
    // Reads the bool stored under `key`, or `defaultValue` when the key has never been written.
    static func read(_ key: String, default defaultValue: Bool, from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
