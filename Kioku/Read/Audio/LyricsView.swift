import SwiftUI
import UIKit

// Floating karaoke-style lyrics popup rendered as an overlay on ReadView.
// Shows the full cue list in a free-scrollable view; the active cue auto-scrolls to center.
// Inactive cues scale down and fade based on distance from the active cue (Apple Music style).
// Bottom controls: play/pause (left), scrubber with timestamps (center), repeat-cue toggle (right).
// Tapping the dimmed backdrop calls onDismiss.
struct LyricsView: View {
    @ObservedObject var controller: AudioPlaybackController
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let segmentColorByLocation: [Int: UIColor]
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    let displayStyle: LyricsDisplayStyle
    let translationCache: LyricsTranslationCache
    let onSegmentTapped: (Int) -> Void
    let onDismiss: () -> Void

    @State private var isRepeatOn = false
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
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }
        }
    }

    // Builds the rounded floating card centered in the screen.
    private func panel(geo: GeometryProxy) -> some View {
        let panelWidth = geo.size.width * 0.9
        let panelHeight = geo.size.height * 0.55

        return VStack(spacing: 0) {
            cueList(panelWidth: panelWidth, height: panelHeight - controlsHeight)
            controls
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
    }

    private let controlsHeight: CGFloat = 56

    // Full cue list — all cues visible, active scrolled to center.
    // Top and bottom padding equals half the list height so the active cue can truly center.
    private func cueList(panelWidth: CGFloat, height: CGFloat) -> some View {
        let halfHeight = height / 2

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { i, cue in
                        let distance = abs(i - (controller.activeCueIndex ?? 0))
                        let isActive = controller.activeCueIndex == i
                        LyricsCueRow(
                            cue: cue,
                            cueIndex: i,
                            isActive: isActive,
                            distanceFromActive: distance,
                            displayStyle: displayStyle,
                            furiganaBySegmentLocation: furiganaBySegmentLocation,
                            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                            segmentationRanges: segmentationRanges,
                            noteText: noteText,
                            highlightRange: i < highlightRanges.count ? highlightRanges[i] : nil,
                            segmentColorByLocation: segmentColorByLocation,
                            translationCache: translationCache,
                            onSegmentTapped: onSegmentTapped,
                            onCueTapped: {
                                controller.seek(toMs: cue.startMs)
                                if controller.isPlaying == false { controller.play() }
                            }
                        )
                        .id(i)
                    }
                }
                // Vertical padding lets the first and last cues scroll to center.
                .padding(.vertical, halfHeight)
                .padding(.horizontal, 16)
            }
            .frame(height: height)
            // Fade top and bottom so cues dissolve naturally into the panel edges.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: controller.activeCueIndex) { _, newIndex in
                guard let newIndex, userIsScrolling == false else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
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
    }

    // Bottom control row: play/pause · scrubber · repeat.
    private var controls: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if controller.isPlaying { controller.pause() } else { controller.play() }
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

            LyricsScrubber(controller: controller)

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
        .frame(height: controlsHeight)
    }
}

// Inline scrubber with timestamps flanking the slider — used only inside LyricsView.
private struct LyricsScrubber: View {
    @ObservedObject var controller: AudioPlaybackController

    @State private var scrubPositionSeconds: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 6) {
            Text(formattedCurrentTime)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)

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

    private var currentPositionSeconds: Double { Double(controller.currentTimeMs) / 1000 }

    private var formattedCurrentTime: String {
        let s = controller.currentTimeMs / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var formattedDuration: String {
        let s = Int(controller.duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
