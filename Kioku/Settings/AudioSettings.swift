import Foundation

enum AudioSettings {
    static let backgroundPlaybackKey = "kioku.settings.audio.backgroundPlayback"
    static let defaultBackgroundPlayback = true

    static let autoAdvanceToNextNoteKey = "kioku.settings.audio.autoAdvanceToNextNote"
    static let defaultAutoAdvanceToNextNote = false

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

    // Whether SongStepperView's Listen-along should automatically move on to the next note in
    // SongsHomeView's list once the current note's track finishes playing on its own. Defaults
    // off — auto-navigating away from the note the user opened is a bigger behavior change than
    // background playback (which just keeps doing what was already asked), so this starts opt-in.
    static var autoAdvanceToNextNoteEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoAdvanceToNextNoteKey) != nil else {
            return defaultAutoAdvanceToNextNote
        }
        return defaults.bool(forKey: autoAdvanceToNextNoteKey)
    }
}
