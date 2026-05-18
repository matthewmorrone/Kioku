import SwiftUI

// Beat-pulsing ♪ glyph shown during no-vocal stretches (intro, ♪ cues, long gaps). Scale and
// opacity track the live audio level so the note pulses with whatever instrumental is playing;
// when audio is paused the level drops to 0 and the glyph rests at its idle size. Sizes tuned
// to read as a single discreet character — not a billboard — in the active-cue slot.
struct PulsingDotsIndicator: View {
    @ObservedObject var controller: AudioPlaybackController

    var body: some View {
        // SwiftUI re-renders the body when controller.audioLevel changes (50ms tick) — that's
        // close enough to a 20fps refresh that we don't need a separate TimelineView for the
        // beat path. The implicit animation smooths the visual transitions between samples.
        let level = controller.audioLevel
        let scale = 0.85 + 0.45 * level
        let opacity = 0.35 + 0.55 * level
        Text("♪")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Color.white.opacity(opacity))
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}
