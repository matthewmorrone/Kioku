import AppIntents
import SwiftUI

// The lyrics Live Activity's transport row: back a line (undo arrow), play/pause, forward a line
// (redo arrow). Each button
// runs a LiveActivityIntent in the app's process, so it works from the Lock Screen and the Dynamic
// Island without opening the app.
struct LyricsActivityControls: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 22) {
            Button(intent: LyricsPreviousLineIntent()) {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel("Previous line")
            Button(intent: LyricsTogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button(intent: LyricsNextLineIntent()) {
                Image(systemName: "arrow.uturn.forward")
            }
            .accessibilityLabel("Next line")
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.primary)
    }
}
