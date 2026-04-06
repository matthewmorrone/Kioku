import SwiftUI

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
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    let displayStyle: LyricsDisplayStyle
    @ObservedObject var translationCache: LyricsTranslationCache
    let onSegmentTapped: (Int) -> Void
    let onDismiss: () -> Void

    @State private var isRepeatOn = false
    // Index highlighted while the user manually browses — overrides activeCueIndex visually.
    // nil = follow playback auto-scroll.
    @State private var browseIndex: Int? = nil
    // Scroll position binding: tracks which cue row is currently scrolled to.
    @State private var scrolledID: Int? = nil
    // Timestamp of the last manual scroll event — used to detect idle threshold (1.5s) before resuming auto-scroll.
    @State private var lastScrollTime: Date = .distantPast
    // True while the scrubber thumb is being dragged; suppresses scroll/playback interference.
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

    // The start time of the browsed cue — only valid while browsing.
    private var browseStartMs: Int? {
        guard let idx = browseIndex, cues.indices.contains(idx) else { return nil }
        return cues[idx].startMs
    }

    // Full cue list — all cues visible, active scrolled to center.
    // Top and bottom padding equals half the list height so the active cue can truly center.
    // The active-cue FuriganaTextRenderer lives as a ZStack overlay so it is never torn down between cue transitions; inactive rows show plain text placeholders.
    private func cueList(panelWidth: CGFloat, height: CGFloat) -> some View {
        let halfHeight = height / 2

        return ScrollViewReader { proxy in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
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
                                    translationCache: translationCache,
                                    onCueTapped: {
                                        controller.seek(toMs: cue.startMs)
                                        browseIndex = i
                                        lastScrollTime = Date()
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            proxy.scrollTo(i, anchor: .center)
                                        }
                                    }
                                )
                                .id(i)
                            }
                        } // LazyVStack
                    } // VStack
                    // Vertical padding lets the first and last cues scroll to center.
                    .padding(.vertical, halfHeight)
                    .padding(.horizontal, 16)
                }
                .frame(height: height)
                .scrollPosition(id: $scrolledID)
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
                // When user scrolls to a different cue, record the browse position.
                // scrollPosition binding does not fire during programmatic proxy.scrollTo calls,
                // so this cleanly distinguishes user scrolls from auto-scroll.
                .onChange(of: scrolledID) { _, newID in
                    guard !isScrubbing, let newID else { return }
                    if newID != controller.activeCueIndex {
                        browseIndex = newID
                        lastScrollTime = Date()
                    }
                }
                // When playback advances, resume auto-scroll if user has been idle 1.5s.
                .onChange(of: controller.activeCueIndex) { _, newIndex in
                    guard let newIndex else { return }
                    // While scrubbing, always scroll immediately to track the drag.
                    if isScrubbing {
                        browseIndex = nil
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                        return
                    }
                    // Resume auto-scroll when playback advances and the user hasn't scrolled recently.
                    let idleThreshold: TimeInterval = 1.5
                    if Date().timeIntervalSince(lastScrollTime) > idleThreshold {
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

                // Persistent active-cue renderer — always mounted so UITextView is never torn down
                // between cue changes. Centered in the list area, layered above the scroll list.
                LyricsActiveCueOverlay(
                    activeCueIndex: browseIndex ?? controller.activeCueIndex,
                    cues: cues,
                    highlightRanges: highlightRanges,
                    furiganaBySegmentLocation: furiganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                    segmentationRanges: segmentationRanges,
                    noteText: noteText,
                    translationCache: translationCache,
                    panelWidth: panelWidth,
                    onSegmentTapped: onSegmentTapped
                )
                .allowsHitTesting(true)
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

            LyricsScrubber(controller: controller, browseTimeMs: browseStartMs, isScrubbing: $isScrubbing)

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
// isScrubbing: bound to LyricsView so it can suppress scroll-position interference during drags.
private struct LyricsScrubber: View {
    @ObservedObject var controller: AudioPlaybackController
    let browseTimeMs: Int?
    @Binding var isScrubbing: Bool

    @State private var scrubPositionSeconds: Double = 0

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

