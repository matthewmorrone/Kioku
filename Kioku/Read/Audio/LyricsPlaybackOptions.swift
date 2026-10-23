import SwiftUI

// The playback toggles shared by the lyrics card's settings popup and the full-screen word view's:
// background audio, continuing to the next note, and the lyric line on the lock screen. One view so
// the two popups always offer the same choices; each toggle writes its AudioSettings key directly.
// Layout: three toggles, stacked.
struct LyricsPlaybackOptions: View {
    @AppStorage(AudioSettings.backgroundPlaybackKey) private var backgroundPlaybackEnabled = AudioSettings.defaultBackgroundPlayback
    @AppStorage(AudioSettings.autoAdvanceToNextNoteKey) private var autoAdvanceToNextNoteEnabled = AudioSettings.defaultAutoAdvanceToNextNote
    @AppStorage(AudioSettings.lyricsOnNowPlayingKey) private var lyricsOnNowPlayingEnabled = AudioSettings.defaultLyricsOnNowPlaying

    var body: some View {
        Toggle("Background Audio", isOn: $backgroundPlaybackEnabled)
        Toggle("Continue to Next Note", isOn: $autoAdvanceToNextNoteEnabled)
        Toggle("Lyrics on Lock Screen", isOn: $lyricsOnNowPlayingEnabled)
    }
}
