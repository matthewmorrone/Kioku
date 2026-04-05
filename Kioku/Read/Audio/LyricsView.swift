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
    // Index highlighted while the user manually browses — overrides activeCueIndex visually.
    @State private var browseIndex: Int? = nil
    // True while the user is scrolling; suppresses playback auto-scroll.
    @State private var userIsScrolling = false
    // Timestamp of the last scroll activity — used to detect when momentum has fully settled.
    @State private var lastScrollTime: Date = .distantPast
    // Set when the user taps a cue to seek; blocks onPreferenceChange from overriding browseIndex
    // until the scroll view has settled on the new position.
    @State private var pendingSeekIndex: Int? = nil
    // True after the first layout pass has fired, so we don't treat initial render as a scroll.
    @State private var hasAppeared = false

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

    // The start time of the browsed cue — only valid while the user is actively scrolling.
    private var browseStartMs: Int? {
        guard userIsScrolling, let idx = browseIndex, cues.indices.contains(idx) else { return nil }
        return cues[idx].startMs
    }

    // Full cue list — all cues visible, active scrolled to center.
    // Top and bottom padding equals half the list height so the active cue can truly center.
    private func cueList(panelWidth: CGFloat, height: CGFloat) -> some View {
        let halfHeight = height / 2

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { i, cue in
                        let highlighted = browseIndex ?? controller.activeCueIndex
                        let distance = abs(i - (highlighted ?? 0))
                        let isActive = highlighted == i
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
                                browseIndex = i
                                pendingSeekIndex = i
                                userIsScrolling = false
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(i, anchor: .center)
                                }
                            }
                        )
                        // Each row reports its center Y in scroll-view coordinates so we can
                        // determine which cue is closest to center during manual scroll.
                        .background(
                            GeometryReader { rowGeo in
                                Color.clear.preference(
                                    key: RowCenterPreferenceKey.self,
                                    value: [i: rowGeo.frame(in: .named("lyricsScroll")).midY]
                                )
                            }
                        )
                        .id(i)
                    }
                }
                // Vertical padding lets the first and last cues scroll to center.
                .padding(.vertical, halfHeight)
                .padding(.horizontal, 16)
            }
            .coordinateSpace(name: "lyricsScroll")
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
            // Update browseIndex to whichever cue is nearest the panel center.
            // Only marks userIsScrolling when the centered cue differs from the playback cue —
            // meaning the user has scrolled away from where audio is, not just that a cue advanced.
            .onPreferenceChange(RowCenterPreferenceKey.self) { centers in
                guard hasAppeared else { hasAppeared = true; return }
                let midY = height / 2
                guard let closest = centers.min(by: { abs($0.value - midY) < abs($1.value - midY) }) else { return }
                if let pending = pendingSeekIndex {
                    if closest.key == pending { pendingSeekIndex = nil }
                    return
                }
                browseIndex = closest.key
                // Only treat as a user scroll when the centered cue differs from playback position.
                if closest.key != controller.activeCueIndex {
                    lastScrollTime = Date()
                    userIsScrolling = true
                }
            }
            .onChange(of: controller.activeCueIndex) { _, newIndex in
                // Resume auto-scroll when playback advances and the user hasn't scrolled recently.
                guard let newIndex else { return }
                let idleThreshold: TimeInterval = 1.5
                if Date().timeIntervalSince(lastScrollTime) > idleThreshold {
                    userIsScrolling = false
                    browseIndex = nil
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
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

            LyricsScrubber(controller: controller, browseTimeMs: browseStartMs)

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
// browseTimeMs: when non-nil (user is scrolling), overrides the displayed position without seeking.
private struct LyricsScrubber: View {
    @ObservedObject var controller: AudioPlaybackController
    let browseTimeMs: Int?

    @State private var scrubPositionSeconds: Double = 0
    @State private var isScrubbing = false

    // Displayed position: browse position > manual scrub > playback position.
    private var displayPositionSeconds: Double {
        if let browse = browseTimeMs, isScrubbing == false {
            return Double(browse) / 1000
        }
        return isScrubbing ? scrubPositionSeconds : Double(controller.currentTimeMs) / 1000
    }

    private var displayTimeMs: Int {
        if let browse = browseTimeMs, isScrubbing == false { return browse }
        return isScrubbing ? Int(scrubPositionSeconds * 1000) : controller.currentTimeMs
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
                    set: { scrubPositionSeconds = $0 }
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

// Collects each cue row's center Y position (in scroll-view coordinates) so LyricsView
// can determine which cue is closest to the panel center during manual scrolling.
private struct RowCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
