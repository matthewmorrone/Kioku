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
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    let onDismiss: () -> Void

    private var activeIndex: Int { controller.activeCueIndex ?? 0 }

    // Number of cues where the subtitle text differs from the corresponding note text.
    private var mismatchCount: Int {
        cues.indices.filter { hasMismatch(at: $0) }.count
    }

    // Returns true when the cue text doesn't match the note text for this index.
    private func hasMismatch(at index: Int) -> Bool {
        let note = displayText(for: index)
        let cue = cues[index].text
        return note != cue && SubtitleParser.isNonSpeechCue(cue.trimmingCharacters(in: .whitespacesAndNewlines)) == false
    }

    @State private var dragStartIndex: Int = 0
    @State private var dragDisplayIndex: Int? = nil
    @State private var isDragging: Bool = false
    @State private var dragOverscrolledToStart: Bool = false
    @State private var isScrubbing = false
    @State private var translationTrigger: TranslationSession.Configuration? = nil
    @StateObject private var translationCache = LyricsTranslationCache()

    @AppStorage(LyricsDisplayStyle.storageKey) private var lyricsDisplayStyleRaw = LyricsDisplayStyle.defaultValue.rawValue

    // Resolves the AppStorage raw string into the typed enum, falling back to the default when
    // the persisted value pre-dates a new style being added.
    private var displayStyle: LyricsDisplayStyle {
        LyricsDisplayStyle(rawValue: lyricsDisplayStyleRaw) ?? LyricsDisplayStyle.defaultValue
    }

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

                // Active cue renderer — uses the SAME CoreText renderer as ReadView, fed the
                // FULL noteText + segments + furigana, then auto-scrolled to the active cue's
                // line via `playbackHighlightRange`. No data slicing — what ReadView shows
                // (segment colors, ruby) renders identically here. The cue's NSRange acts as
                // the scroll target; the highlight color is transparent so the band itself is
                // invisible. Falls back to nil when the cue is non-speech (♪) or unresolved.
                let cueRange: NSRange? = (displayIndex < highlightRanges.count) ? highlightRanges[displayIndex] : nil
                VStack(spacing: 0) {
                    KiokuCoreTextRendererView(
                        text: noteText,
                        segmentationRanges: segmentationRanges,
                        furiganaBySegmentLocation: furiganaBySegmentLocation,
                        furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                        isFuriganaVisible: true,
                        isVisualEnhancementsEnabled: true,
                        isColorAlternationEnabled: true,
                        textSize: Binding(get: { TypographySettings.defaultTextSize }, set: { _ in }),
                        lineSpacing: 0,
                        kerning: 0,
                        furiganaGap: CGFloat(TypographySettings.defaultFuriganaGap),
                        evenSegmentColor: UIColor { tc in tc.userInterfaceStyle == .dark ? .systemOrange : .systemRed },
                        oddSegmentColor: UIColor { tc in tc.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo },
                        isLineWrappingEnabled: true,
                        isRubySpacingEnabled: true,
                        selectedHighlightRange: nil,
                        playbackHighlightRange: cueRange,
                        selectionHighlightColor: .clear,
                        // Transparent — the cue range is used purely to drive auto-scroll, not
                        // to paint a highlight band on the active line.
                        playbackHighlightColor: .clear,
                        unknownSegmentLocations: [],
                        isHighlightUnknownEnabled: false,
                        unknownSegmentColor: .label,
                        debugFlags: KiokuDebugOverlayView.Flags(),
                        illegalMergeLocation: nil,
                        onSegmentTapped: { globalLocation, rect in
                            // Locations are already in noteText UTF-16 coords — no translation
                            // needed. sourceView is nil because the CT path doesn't expose a
                            // UITextView; popover anchoring falls back to a default.
                            onSegmentTapped(globalLocation, rect, nil)
                        },
                        isScrollEnabled: false,
                        textAlignment: .center
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: rendererHeight)
                    .clipped()
                    if let translation = translationCache.translations[displayIndex] {
                        Text(translation)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .italic()
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    if displayIndex < cues.count && hasMismatch(at: displayIndex) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 5, height: 5)
                            Text("Subtitle: \(cues[displayIndex].text)")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(activeCueBackground)
                .overlay(alignment: .leading) { activeCueAccent }
                .padding(.horizontal, displayStyle == .focusCard ? 8 : 0)
                .translationTask(translationTrigger) { session in
                    // Batch-translate all untranslated cues up front so translations are ready during playback.
                    await translateAllCues(session: session)
                }
                .onAppear {
                    translationTrigger = translationConfig
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
            DragGesture(minimumDistance: 8)
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

    // Inactive cue row — plain text whose visual treatment depends on the selected lyrics style.
    // Apple Music: bold weight, leading-aligned, opacity fade with mild scale, no blur.
    // Accent Bar: center-aligned, scale + opacity + blur fall-off — the "karaoke depth" feel.
    // Focus Card: center-aligned, opacity-only fade so the active card stands out without motion.
    @ViewBuilder
    private func inactiveCueRow(index: Int, distance: Int) -> some View {
        let style = displayStyle
        let metrics = inactiveCueMetrics(distance: distance, style: style)
        let defaultSize = CGFloat(TypographySettings.defaultTextSize)
        let text = displayText(for: index)
        let scaleFactor = distance == 0 ? scaleFactorForActiveCue(text: text, availableWidth: 280, defaultFontSize: defaultSize) : 1.0
        let fontSize = defaultSize * scaleFactor
        let leading = style == .appleMusic
        let textAlignment: TextAlignment = leading ? .leading : .center
        let frameAlignment: Alignment = leading ? .leading : .center
        let scaleAnchor: UnitPoint = leading ? .leading : .center

        HStack(spacing: 4) {
            if hasMismatch(at: index) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: fontSize, weight: leading ? .semibold : .regular))
                .multilineTextAlignment(textAlignment)
                .lineLimit(1)
            if leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .frame(height: activeCueRendererHeight)
        .padding(.horizontal, 16)
        .scaleEffect(metrics.scale, anchor: scaleAnchor)
        .opacity(metrics.opacity)
        .blur(radius: metrics.blur)
    }

    // Returns scale, opacity, and blur for an inactive cue based on its distance from the active cue and the active style.
    private func inactiveCueMetrics(distance: Int, style: LyricsDisplayStyle) -> (scale: Double, opacity: Double, blur: Double) {
        switch style {
        case .appleMusic:
            return (
                scale: max(0.78, 1.0 - Double(distance) * 0.06),
                opacity: max(0.25, 1.0 - Double(distance) * 0.18),
                blur: 0
            )
        case .accentBar:
            return (
                scale: max(0.6, 1.0 - Double(distance) * 0.12),
                opacity: max(0.3, 1.0 - Double(distance) * 0.12),
                blur: Double(distance) * 1.2
            )
        case .focusCard:
            return (
                scale: 1.0,
                opacity: max(0.32, 0.78 - Double(distance) * 0.14),
                blur: 0
            )
        }
    }

    // Optional rounded background applied behind the active cue — only the focus-card style draws a card.
    @ViewBuilder
    private var activeCueBackground: some View {
        switch displayStyle {
        case .focusCard:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        case .appleMusic, .accentBar:
            EmptyView()
        }
    }

    // Vertical accent strip drawn at the leading edge of the active cue when the accent-bar style is active.
    @ViewBuilder
    private var activeCueAccent: some View {
        if displayStyle == .accentBar {
            Capsule()
                .fill(Color.orange.opacity(0.85))
                .frame(width: 3)
                .padding(.vertical, 6)
        } else {
            EmptyView()
        }
    }

    // Calculates the scale factor needed to fit the active cue on a single line without wrapping.
    // Measures the text at default size and scales down if necessary to fit within available width.
    private func scaleFactorForActiveCue(text: String, availableWidth: CGFloat, defaultFontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: defaultFontSize)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let requiredScale = min(1.0, availableWidth / textSize.width)
        // Clamp to reasonable bounds: don't go below 0.5x or above 1.0x
        return min(1.0, max(0.5, requiredScale))
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

    // Batch-translates all cues that haven't been cached yet so translations are available during playback.
    // Uses the note text (via displayText) rather than cue text so translations match what's shown.
    private func translateAllCues(session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            return
        }
        for index in cues.indices {
            let text = displayText(for: index)
            guard translationCache.needsTranslation(cueIndex: index, text: text) else { continue }
            do {
                let response = try await session.translate(text)
                await MainActor.run { translationCache.store(cueIndex: index, result: response.targetText) }
            } catch {
                // Individual cue failure is non-fatal — skip and continue.
            }
        }
    }

    // Returns the note text for a cue if a highlight range exists, otherwise the raw cue text.
    // Used for inactive rows and translation so they always show the original note content.
    private func displayText(for cueIndex: Int) -> String {
        guard cueIndex < highlightRanges.count,
              let range = highlightRanges[cueIndex],
              let swiftRange = Range(range, in: noteText) else {
            return cueIndex < cues.count ? cues[cueIndex].text : ""
        }
        return String(noteText[swiftRange])
    }

    private var controls: some View {
        VStack(spacing: 0) {
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
