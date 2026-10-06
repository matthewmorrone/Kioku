import SwiftUI

// The waveform shown beside the note title while the song plays, a pause glyph while it's paused.
// The waveform asks for the system's iterative variable-colour effect so its bars ripple where the
// system allows a Live Activity to animate; where it doesn't, it renders as the still waveform.
struct LyricsPlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        if isPlaying {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                .foregroundStyle(WidgetTheme.vermilion)
        } else {
            Image(systemName: "pause.fill")
                .foregroundStyle(WidgetTheme.vermilion)
        }
    }
}
