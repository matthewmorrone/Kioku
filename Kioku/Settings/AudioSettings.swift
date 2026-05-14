import Foundation

enum AudioSettings {
    static let backgroundPlaybackKey = "kioku.settings.audio.backgroundPlayback"
    static let defaultBackgroundPlayback = true

    // Read the toggle from UserDefaults, falling back to the default when the key has never
    // been written — @AppStorage in SettingsView only persists once the user touches the row.
    // The explicit nil-check avoids the NSNumber-vs-Bool footgun in `object(forKey:) as? Bool`.
    static var backgroundPlaybackEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: backgroundPlaybackKey) != nil else {
            return defaultBackgroundPlayback
        }
        return defaults.bool(forKey: backgroundPlaybackKey)
    }
}
