import SwiftUI

// Renders the audio playback controls shown below the editor when the active note has an audio
// attachment. Updates highlightRange whenever the active cue changes so FuriganaTextRenderer
// can visually track the currently spoken subtitle.
struct AudioPlayerBar: View {
    @ObservedObject var controller: AudioPlaybackController
    // Cues loaded for the current note's audio attachment.
    var cues: [SubtitleCue]
    // Writes the NSRange of the active cue back to ReadView for text highlighting.
    @Binding var highlightRange: NSRange?

    var body: some View {
        HStack(spacing: 12) {
            // Play / pause toggle.
            Button {
                if controller.isPlaying {
                    controller.pause()
                } else {
                    controller.play()
                }
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            // Scrubber bar that reflects playback progress and accepts taps to seek.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemFill))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * playbackFraction, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let fraction = location.x / max(proxy.size.width, 1)
                    let ms = Int(fraction * controller.duration * 1000)
                    controller.seek(toMs: ms)
                }
            }
            .frame(height: 34)

            // Current playback position displayed as M:SS.
            Text(formattedTime)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
        // Propagate active cue changes to ReadView's highlight binding.
        .onChange(of: controller.activeCueIndex) { _, newIndex in
            applyHighlight(for: newIndex)
        }
        .onDisappear {
            // Clear highlight so it doesn't linger when the bar is hidden.
            highlightRange = nil
        }
    }

    // Fraction of total duration elapsed; clamped to [0, 1].
    private var playbackFraction: CGFloat {
        guard controller.duration > 0 else { return 0 }
        return CGFloat(min(Double(controller.currentTimeMs) / (controller.duration * 1000), 1.0))
    }

    // Converts milliseconds to a M:SS string for the elapsed time label.
    private var formattedTime: String {
        let totalSeconds = controller.currentTimeMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Resolves the NSRange of the cue at the given index and writes it to the binding.
    private func applyHighlight(for index: Int?) {
        guard let index, index < cues.count else {
            highlightRange = nil
            return
        }
        let cue = cues[index]
        highlightRange = NSRange(location: cue.utf16Start, length: cue.utf16End - cue.utf16Start)
    }
}
