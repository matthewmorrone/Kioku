import Foundation

enum AudioSettings {
    static let backgroundPlaybackKey = "kioku.settings.audio.backgroundPlayback"
    static let defaultBackgroundPlayback = true

    static let autoAdvanceToNextNoteKey = "kioku.settings.audio.autoAdvanceToNextNote"
    static let defaultAutoAdvanceToNextNote = false

    static let lyricsOnNowPlayingKey = "kioku.settings.audio.lyricsOnNowPlaying"
    static let defaultLyricsOnNowPlaying = true

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

    // Whether the system Now Playing card (lock screen, Control Center, CarPlay) shows the current
    // lyric line as its title, with the note's title moved to the artist slot. Defaults on: it only
    // changes what the card says while a note with timed lyrics is playing.
    static var lyricsOnNowPlayingEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: lyricsOnNowPlayingKey) != nil else {
            return defaultLyricsOnNowPlaying
        }
        return defaults.bool(forKey: lyricsOnNowPlayingKey)
    }
}
