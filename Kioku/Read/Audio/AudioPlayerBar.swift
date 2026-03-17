import SwiftUI

// Renders a compact play/pause button for notes with an audio attachment.
// Long-pressing the button reveals a bottom sheet with the scrubber, restart,
// and subtitle-edit actions.
struct AudioPlayerBar: View {
    @ObservedObject var controller: AudioPlaybackController
    // Writes the NSRange of the active cue back to ReadView for text highlighting.
    @Binding var highlightRange: NSRange?
    // Called when the user requests to edit the subtitle file.
    var onEditSubtitles: () -> Void

    @State private var isShowingControls = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .onTapGesture {
            if controller.isPlaying { controller.pause() } else { controller.play() }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            isShowingControls = true
        }
        .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
        .sheet(isPresented: $isShowingControls) {
            expandedControls
                .presentationDetents([.height(160)])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            // Clear highlight so it doesn't linger when the bar is hidden.
            highlightRange = nil
        }
    }

    // Bottom sheet content: scrubber, time, restart, and edit-subtitles actions.
    @ViewBuilder
    private var expandedControls: some View {
        VStack(spacing: 20) {
            // Tappable scrubber with elapsed time label.
            HStack(spacing: 12) {
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
                        let ms = Int((location.x / max(proxy.size.width, 1)) * controller.duration * 1000)
                        controller.seek(toMs: ms)
                    }
                }
                .frame(height: 36)

                Text(formattedTime)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            // Secondary actions: restart playback and open subtitle editor.
            HStack {
                Button {
                    controller.seek(toMs: 0)
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    isShowingControls = false
                    onEditSubtitles()
                } label: {
                    Label("Edit Subtitles", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // Fraction of total duration elapsed; clamped to [0, 1].
    private var playbackFraction: CGFloat {
        guard controller.duration > 0 else { return 0 }
        return CGFloat(min(Double(controller.currentTimeMs) / (controller.duration * 1000), 1.0))
    }

    // Converts milliseconds to a M:SS string for the elapsed time label.
    private var formattedTime: String {
        let totalSeconds = controller.currentTimeMs / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
