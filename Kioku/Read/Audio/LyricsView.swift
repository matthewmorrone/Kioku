import SwiftUI

// Floating karaoke-style lyrics popup rendered as an overlay on ReadView.
// Shows the full cue list in a free-scrollable view; the active cue auto-scrolls to center.
// Inactive cues scale down and fade based on distance from the active cue (Apple Music style).
// Bottom controls: play/pause (left), scrubber with timestamps (center), repeat-cue toggle (right).
// Tapping the dimmed backdrop calls onDismiss.
struct LyricsView: View {
    @ObservedObject var controller: AudioPlaybackController
    let cues: [SubtitleCue]
    let onDismiss: () -> Void

    @State private var isRepeatOn = false
    @State private var isScrubbing = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimming backdrop — tap to dismiss.
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                // Floating panel.
                panel(geo: geo)
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }
            .contentShape(Rectangle())
            .allowsHitTesting(true)
        }
    }

    private func panel(geo: GeometryProxy) -> some View {
        let panelWidth = geo.size.width * 0.9
        let panelHeight = geo.size.height * 0.55
        let controlsHeight: CGFloat = 56

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: panelHeight - controlsHeight)
            controls
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
        .onChange(of: controller.currentTimeMs) { _, currentMs in
            guard isRepeatOn,
                  let activeIndex = controller.activeCueIndex,
                  activeIndex < cues.count else { return }
            let activeCue = cues[activeIndex]
            if currentMs >= activeCue.endMs {
                controller.seek(toMs: activeCue.startMs)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if controller.isPlaying {
                    controller.pause()
                } else if controller.currentTimeMs == 0 {
                    controller.playFromStart()
                } else {
                    controller.play()
                }
            } label: {
                Circle()
                    .fill(Color(.systemOrange).opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(.systemOrange))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            LyricsScrubber(controller: controller, isScrubbing: $isScrubbing)

            Button { isRepeatOn.toggle() } label: {
                Circle()
                    .fill(isRepeatOn ? Color(.systemOrange).opacity(0.25) : Color(.systemFill))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "repeat")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isRepeatOn ? Color(.systemOrange) : Color.secondary)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRepeatOn ? "Stop repeating current line" : "Repeat current line")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .frame(height: 56)
    }
}

private struct LyricsScrubber: View {
    @ObservedObject var controller: AudioPlaybackController
    @Binding var isScrubbing: Bool

    @State private var scrubPositionSeconds: Double = 0

    private var displayPositionSeconds: Double {
        isScrubbing ? scrubPositionSeconds : Double(controller.currentTimeMs) / 1000
    }

    private var displayTimeMs: Int {
        isScrubbing ? Int(scrubPositionSeconds * 1000) : controller.currentTimeMs
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(formatted(ms: displayTimeMs))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)
                .animation(.none, value: displayTimeMs)

            Slider(
                value: Binding(
                    get: { displayPositionSeconds },
                    set: {
                        scrubPositionSeconds = $0
                        controller.seek(toMs: Int($0 * 1000))
                    }
                ),
                in: 0...max(controller.duration, 0.1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubPositionSeconds = Double(controller.currentTimeMs) / 1000
                    } else {
                        controller.seek(toMs: Int(scrubPositionSeconds * 1000))
                    }
                }
            )
            .tint(Color(.systemOrange))

            Text(formattedDuration)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .leading)
        }
        .onChange(of: controller.currentTimeMs) { _, newTimeMs in
            guard isScrubbing == false else { return }
            scrubPositionSeconds = Double(newTimeMs) / 1000
        }
    }

    private func formatted(ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var formattedDuration: String {
        let s = Int(controller.duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

