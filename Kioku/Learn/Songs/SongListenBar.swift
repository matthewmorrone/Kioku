import SwiftUI

// Playback strip pinned under the breakdown's card list while listen-along is on. The cards
// themselves are the transcript (SongStepperView rings the line being spoken and tints the
// exact row), so this bar only carries what the cards can't: render progress until the
// track exists, then play/pause, the elapsed/total readout, an export button, and a way to
// turn listen-along off. Layout is one row; the rendering and failed states swap the
// controls for a progress bar or a Retry.
struct SongListenBar: View {
    let state: SongListenRenderState
    @ObservedObject var playback: AudioPlaybackController
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            switch state {
            case .rendering(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: .infinity)
            case .ready(let url):
                Button {
                    playback.isPlaying ? playback.pause() : playback.play()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Text(timeLabel(playback.currentTimeMs) + " / " + timeLabel(Int(playback.duration * 1000)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Export audio")
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop listening")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // Formats a millisecond offset as m:ss for the elapsed/total readout.
    private func timeLabel(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
