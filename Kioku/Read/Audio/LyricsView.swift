import SwiftUI
import Translation
import UIKit

// Floating karaoke-style lyrics popup rendered as an overlay on ReadView.
// Active cue is a persistent FuriganaTextRenderer fixed at center; inactive cues scroll past it.
// Tapping an inactive cue seeks to it. Playback auto-scrolls when user is idle.
// Bottom controls: play/pause, scrubber, repeat-cue toggle.
struct LyricsView: View {
    @ObservedObject var controller: AudioPlaybackController
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    let attachmentID: UUID?
    let onDismiss: () -> Void

    private var activeIndex: Int { controller.activeCueIndex ?? 0 }

    @State private var dragStartIndex: Int = 0
    @State private var dragDisplayIndex: Int? = nil
    @State private var isDragging: Bool = false
    @State private var dragOverscrolledToStart: Bool = false
    @State private var isScrubbing = false
    @State private var translationSession: TranslationSession? = nil
    @StateObject private var translationCache = LyricsTranslationCache()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                panel(geo: geo)
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }
            .contentShape(Rectangle())
            .allowsHitTesting(true)
        }
    }

    // Height that fits one line of text with furigana above, matching sizeThatFits in FuriganaTextRenderer.
    private var activeCueRendererHeight: CGFloat {
        let textSize = TypographySettings.defaultTextSize
        let bodyFont = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        return furiganaFont.lineHeight + CGFloat(TypographySettings.defaultFuriganaGap) + 4 + bodyFont.lineHeight + 8
    }

    // Builds the main lyrics panel showing the scrollable cue history above the active-cue renderer.
    private func panel(geo: GeometryProxy) -> some View {
        let panelWidth = geo.size.width * 0.9
        let panelHeight = geo.size.height * 0.55
        let rendererHeight = activeCueRendererHeight
        let displayIndex = dragDisplayIndex ?? activeIndex

        return VStack(spacing: 0) {
            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    ForEach(0 ..< displayIndex, id: \.self) { index in
                        let distance = displayIndex - index
                        inactiveCueRow(index: index, distance: distance)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDisabled(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.seek(toMs: cues[max(0, activeIndex - 1)].startMs)
            }

            // Active cue renderer — always mounted, never torn down between cue changes.
            let rendererData = buildRendererData(for: displayIndex)
            VStack(spacing: 0) {
                FuriganaTextRenderer(
                    isActive: true,
                    isOverlayFrozen: false,
                    text: rendererData?.surface ?? "",
                    isLineWrappingEnabled: true,
                    segmentationRanges: rendererData?.localSegRanges ?? [],
                    selectedSegmentLocation: nil,
                    blankSelectedSegmentLocation: nil,
                    selectedHighlightRangeOverride: nil,
                    playbackHighlightRangeOverride: nil,
                    activePlaybackCueIndex: nil,
                    illegalMergeBoundaryLocation: nil,
                    furiganaBySegmentLocation: rendererData?.localFurigana ?? [:],
                    furiganaLengthBySegmentLocation: rendererData?.localFuriganaLength ?? [:],
                    isVisualEnhancementsEnabled: true,
                    isColorAlternationEnabled: true,
                    isHighlightUnknownEnabled: false,
                    unknownSegmentLocations: [],
                    changedSegmentLocations: [],
                    changedReadingLocations: [],
                    customEvenSegmentColorHex: "",
                    customOddSegmentColorHex: "",
                    debugFuriganaRects: false,
                    debugHeadwordRects: false,
                    debugHeadwordLineBands: false,
                    debugFuriganaLineBands: false,
                    externalContentOffsetY: 0,
                    onScrollOffsetYChanged: { _ in },
                    onSegmentTapped: { _, _, _ in },
                    textSize: Binding(get: { TypographySettings.defaultTextSize * 1.3 }, set: { _ in }),
                    lineSpacing: 0,
                    kerning: 0,
                    furiganaGap: TypographySettings.defaultFuriganaGap,
                    textAlignment: .center,
                    isScrollEnabled: false
                )
                .frame(maxWidth: .infinity)
                .frame(height: rendererHeight)
                if let translation = translationCache.translations[displayIndex] {
                    Text(translation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .italic()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            // .border(Color(.systemOrange).opacity(0.3), width: 1)
            // .background(Color(.systemOrange).opacity(0.12))
            // .clipShape(RoundedRectangle(cornerRadius: 12))
            // .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.systemOrange).opacity(0.3), lineWidth: 1))
            .translationTask(translationConfig) { session in
                translationSession = session
                if displayIndex < cues.count {
                    await translateCue(session: session, index: displayIndex, text: cues[displayIndex].text)
                }
            }
            .onChange(of: displayIndex) { _, newIndex in
                guard newIndex < cues.count, let session = translationSession else { return }
                Task { await translateCue(session: session, index: newIndex, text: cues[newIndex].text) }
            }

            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    ForEach((displayIndex + 1) ..< cues.count, id: \.self) { index in
                        let distance = index - displayIndex
                        inactiveCueRow(index: index, distance: distance)
                    }
                }
            }
            .defaultScrollAnchor(.top)
            .scrollDisabled(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.seek(toMs: cues[min(cues.count - 1, activeIndex + 1)].startMs)
            }
            } // end lyric VStack
            .clipped()

            controls
        }
        .frame(width: panelWidth, height: panelHeight)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartIndex = activeIndex
                    }
                    let steps = Int(-value.translation.height / rendererHeight)
                    let raw = dragStartIndex + steps
                    dragOverscrolledToStart = raw < 0
                    dragDisplayIndex = min(cues.count - 1, max(0, raw))
                }
                .onEnded { _ in
                    isDragging = false
                    if dragOverscrolledToStart {
                        controller.seek(toMs: 0)
                    } else if let target = dragDisplayIndex {
                        controller.seek(toMs: cues[target].startMs)
                    }
                    dragDisplayIndex = nil
                    dragOverscrolledToStart = false
                }
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
        .onAppear {
            if let attachmentID { translationCache.load(for: attachmentID) }
        }
    }

    // Inactive cue row — plain text, scaled, faded, and blurred by distance from the active cue.
    @ViewBuilder
    private func inactiveCueRow(index: Int, distance: Int) -> some View {
        let scale = max(0.6, 1.0 - Double(distance) * 0.12)
        let opacity = max(0.3, 1.0 - Double(distance) * 0.12)
        let blur = Double(distance) * 1.2

        Text(cues[index].text)
            .font(.system(size: CGFloat(TypographySettings.defaultTextSize)))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: activeCueRendererHeight)
            .padding(.horizontal, 16)
            .scaleEffect(scale)
            .opacity(opacity)
            .blur(radius: blur)
    }

    private var translationConfig: TranslationSession.Configuration {
        let target = Locale.preferredLanguages
            .first(where: { !$0.hasPrefix("ja") })
            .map { Locale.Language(identifier: $0) }
            ?? Locale.Language(identifier: "en-US")
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: target
        )
    }

    // Requests a machine translation for one cue and stores the result in the cache for subsequent renders.
    private func translateCue(session: TranslationSession, index: Int, text: String) async {
        guard translationCache.needsTranslation(cueIndex: index, text: text) else { return }
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            await MainActor.run { translationCache.store(cueIndex: index, result: response.targetText) }
        } catch {
            // Failures are silent — the translation row simply won't appear.
        }
    }

    // Extracts the note text slice and per-segment furigana for a cue so the active-cue renderer can display it with readings.
    private func buildRendererData(for cueIndex: Int) -> (surface: String, localSegRanges: [Range<String.Index>], localFurigana: [Int: String], localFuriganaLength: [Int: Int])? {
        guard cueIndex < highlightRanges.count,
              let highlightRange = highlightRanges[cueIndex],
              let swiftRange = Range(highlightRange, in: noteText) else { return nil }

        let surface = String(noteText[swiftRange])
        let surfaceBase = highlightRange.location

        var localSegRanges: [Range<String.Index>] = []
        for segRange in segmentationRanges {
            let nsRange = NSRange(segRange, in: noteText)
            guard NSIntersectionRange(nsRange, highlightRange).length > 0 else { continue }
            let localOffset = nsRange.location - surfaceBase
            if let localRange = Range(NSRange(location: localOffset, length: nsRange.length), in: surface) {
                localSegRanges.append(localRange)
            }
        }

        var localFurigana: [Int: String] = [:]
        for (location, reading) in furiganaBySegmentLocation {
            guard location >= highlightRange.location,
                  location < highlightRange.location + highlightRange.length else { continue }
            localFurigana[location - surfaceBase] = reading
        }

        var localFuriganaLength: [Int: Int] = [:]
        for (location, length) in furiganaLengthBySegmentLocation {
            guard location >= highlightRange.location,
                  location < highlightRange.location + highlightRange.length else { continue }
            localFuriganaLength[location - surfaceBase] = length
        }

        return (surface: surface, localSegRanges: localSegRanges, localFurigana: localFurigana, localFuriganaLength: localFuriganaLength)
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

            LyricsScrubber(
                controller: controller,
                isScrubbing: $isScrubbing,
                overrideTimeMs: dragOverscrolledToStart ? 0 : dragDisplayIndex.map { cues[$0].startMs }
            )

            Circle()
                .fill(Color(.systemFill))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                )
                .onTapGesture {
                    guard activeIndex < cues.count else { return }
                    controller.seek(toMs: cues[activeIndex].startMs)
                }
                .onLongPressGesture {
                    controller.seek(toMs: 0)
                }
                .accessibilityLabel("Return to start of line")
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
    var overrideTimeMs: Int? = nil

    @State private var scrubPositionSeconds: Double = 0

    private var displayPositionSeconds: Double {
        if let override = overrideTimeMs { return Double(override) / 1000 }
        return isScrubbing ? scrubPositionSeconds : Double(controller.currentTimeMs) / 1000
    }

    private var displayTimeMs: Int {
        if let override = overrideTimeMs { return override }
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

    // Formats a millisecond timestamp as M:SS for the scrubber time label.
    private func formatted(ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var formattedDuration: String {
        let s = Int(controller.duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
