import SwiftUI

// Compact bottom-row playback button with restart and subtitle-edit affordances.
struct AudioPlayerButton: View {
    @ObservedObject var controller: AudioPlaybackController
    @Binding var isScrubberVisible: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .onTapGesture {
                if controller.isPlaying {
                    controller.pause()
                } else {
                    controller.play()
                    isScrubberVisible = true
                }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                controller.seek(toMs: 0)
                controller.play()
                isScrubberVisible = true
            }
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
            .accessibilityHint("Press and hold to restart playback")

            Button {
                isScrubberVisible.toggle()
            } label: {
                Image(systemName: isScrubberVisible ? "chevron.down" : "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isScrubberVisible ? "Hide Scrubber" : "Show Scrubber")
        }
    }
}

// Dedicated playback scrubber row that appears only while audio is playing.
struct AudioPlaybackScrubber: View {
    @ObservedObject var controller: AudioPlaybackController

    @State private var scrubPositionSeconds: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPositionSeconds : currentPositionSeconds },
                    set: { scrubPositionSeconds = $0 }
                ),
                in: 0...max(controller.duration, 0.1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubPositionSeconds = currentPositionSeconds
                    } else {
                        controller.seek(toMs: Int(scrubPositionSeconds * 1000))
                    }
                }
            )
            .tint(.accentColor)

            Text(formattedTime)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .onChange(of: controller.currentTimeMs) { _, newTimeMs in
            guard isScrubbing == false else {
                return
            }
            scrubPositionSeconds = Double(newTimeMs) / 1000
        }
    }

    private var currentPositionSeconds: Double {
        Double(controller.currentTimeMs) / 1000
    }

    private var formattedTime: String {
        let totalSeconds = controller.currentTimeMs / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
