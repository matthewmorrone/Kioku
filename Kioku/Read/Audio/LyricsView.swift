import SwiftUI

// Floating karaoke-style lyrics popup rendered as an overlay on ReadView.
// Shows all subtitle cues in a free-scrollable list; the active cue auto-scrolls into view.
// Bottom controls: play/pause (left), scrubber (center), repeat-cue toggle (right).
// Tapping the dimmed backdrop behind the popup calls onDismiss.
// Major sections: backdrop, floating panel (cue list + bottom controls).
struct LyricsView: View {
    @ObservedObject var controller: AudioPlaybackController
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    let displayStyle: LyricsDisplayStyle
    let translationCache: LyricsTranslationCache
    let onSegmentTapped: (Int) -> Void
    let onDismiss: () -> Void

    @State private var isRepeatOn = false
    // Tracks whether the user is manually scrolling so auto-scroll doesn't fight them.
    @State private var userIsScrolling = false

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
                    // Prevent taps on the panel from propagating to the backdrop.
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }
        }
    }

    // Builds the rounded floating card centered in the screen.
    private func panel(geo: GeometryProxy) -> some View {
        let panelWidth = geo.size.width * 0.9
        let panelHeight = geo.size.height * 0.5

        return VStack(spacing: 0) {
            cueList(height: panelHeight - controlsHeight)
            controls
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
    }

    private let controlsHeight: CGFloat = 56

    // Scrollable cue list with a fade-out gradient at the bottom.
    private func cueList(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(cues.enumerated()), id: \.element.index) { i, cue in
                        LyricsCueRow(
                            cue: cue,
                            cueIndex: i,
                            isActive: controller.activeCueIndex == i,
                            distanceFromActive: abs(i - (controller.activeCueIndex ?? 0)),
                            displayStyle: displayStyle,
                            furiganaBySegmentLocation: furiganaBySegmentLocation,
                            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                            segmentationRanges: segmentationRanges,
                            noteText: noteText,
                            highlightRange: i < highlightRanges.count ? highlightRanges[i] : nil,
                            translationCache: translationCache,
                            onSegmentTapped: onSegmentTapped,
                            onCueTapped: {
                                controller.seek(toMs: cue.startMs)
                                if controller.isPlaying == false {
                                    controller.play()
                                }
                            }
                        )
                        .id(i)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .frame(height: height)
            // Fade the bottom of the cue list into the controls.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.75),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: controller.activeCueIndex) { _, newIndex in
                // Auto-scroll to the new active cue when not manually scrolling.
                guard let newIndex, userIsScrolling == false else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onChange(of: controller.currentTimeMs) { _, currentMs in
                // Repeat-cue logic: seek back to cue start when it ends.
                guard isRepeatOn,
                      let activeIndex = controller.activeCueIndex,
                      activeIndex < cues.count else { return }
                let activeCue = cues[activeIndex]
                if currentMs >= activeCue.endMs {
                    controller.seek(toMs: activeCue.startMs)
                }
            }
        }
    }

    // Bottom control row: play/pause · scrubber · repeat.
    private var controls: some View {
        HStack(spacing: 10) {
            // Play/pause button — 22pt.
            Button {
                if controller.isPlaying {
                    controller.pause()
                } else {
                    controller.play()
                }
            } label: {
                Circle()
                    .fill(Color(.systemOrange).opacity(0.2))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(.systemOrange))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            // Scrubber with timestamps below.
            LyricsScrubber(controller: controller)

            // Repeat-cue toggle — 22pt.
            Button {
                isRepeatOn.toggle()
            } label: {
                Circle()
                    .fill(isRepeatOn ? Color(.systemOrange).opacity(0.25) : Color(.systemFill))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "repeat")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isRepeatOn ? Color(.systemOrange) : Color.secondary)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRepeatOn ? "Stop repeating current line" : "Repeat current line")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .frame(height: controlsHeight)
    }
}

// Inline scrubber with timestamps below the track — used only inside LyricsView.
private struct LyricsScrubber: View {
    @ObservedObject var controller: AudioPlaybackController

    @State private var scrubPositionSeconds: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 2) {
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
            .tint(Color(.systemOrange))
            .controlSize(.mini)

            HStack {
                Text(formattedCurrentTime)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedDuration)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: controller.currentTimeMs) { _, newTimeMs in
            guard isScrubbing == false else { return }
            scrubPositionSeconds = Double(newTimeMs) / 1000
        }
    }

    private var currentPositionSeconds: Double {
        Double(controller.currentTimeMs) / 1000
    }

    private var formattedCurrentTime: String {
        let s = controller.currentTimeMs / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var formattedDuration: String {
        let s = Int(controller.duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
