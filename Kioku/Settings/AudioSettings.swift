import Foundation

enum AudioSettings {
    static let backgroundPlaybackKey = "kioku.settings.audio.backgroundPlayback"
    static let defaultBackgroundPlayback = true

    // Read the toggle from UserDefaults, falling back to the default when the key has never
    // been written — @AppStorage in SettingsView only persists once the user touches the row.
    static var backgroundPlaybackEnabled: Bool {
        UserDefaults.standard.object(forKey: backgroundPlaybackKey) as? Bool ?? defaultBackgroundPlayback
    }
}
