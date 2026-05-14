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

    // Active-cue render input — slices noteText to ONLY the active cue's text and rebases
    // the furigana table to cue-local coordinates. The renderer then has exactly one cue's
    // worth of content, so adjacent cues cannot bleed in. Falls back to the cue's raw text
    // when no noteText range is available (e.g., non-speech cue, alignment didn't resolve).
    private struct ActiveCueRenderInput {
        let text: String
        let furiganaBySegmentLocation: [Int: String]
        let furiganaLengthBySegmentLocation: [Int: Int]
        let segmentationRanges: [Range<String.Index>]
    }

    // Builds the sliced render input for the cue at `index`. Strategy:
    //   1. Resolve the cue's NSRange in noteText. Try `highlightRanges[index]` first; fall
    //      back to a substring search if that lookup is nil (non-speech cue, alignment not
    //      yet resolved, etc.) so the cue still renders with full furigana.
    //   2. Filter furigana entries to those whose kanji-run start sits inside the cue and
    //      rebase locations to cue-local UTF-16 coords.
    //   3. Clip each segmentation range to the cue's bounds (don't drop boundary-crossing
    //      segments — that would leave their characters uncolored). Classic CT layout
    //      tolerates clipped sub-segments, so this is safe.
    //   4. If no noteText match exists at all, fall back to the raw cue text without
    //      furigana — the user still sees the line.
    private func activeCueRenderInput(for index: Int) -> ActiveCueRenderInput {
        guard index >= 0, index < cues.count else {
            return ActiveCueRenderInput(text: "", furiganaBySegmentLocation: [:], furiganaLengthBySegmentLocation: [:], segmentationRanges: [])
        }

        // Resolve cue range in noteText — prefer the matched highlight range, but also
        // probe by substring so a missing/nil highlight still finds the cue text when it
        // appears verbatim in noteText.
        let resolvedRange: NSRange? = {
            if index < highlightRanges.count, let r = highlightRanges[index] { return r }
            let cueText = cues[index].text
            guard cueText.isEmpty == false else { return nil }
            let probe = (noteText as NSString).range(of: cueText)
            return probe.location == NSNotFound ? nil : probe
        }()

        guard let cueRange = resolvedRange,
              let swiftRange = Range(cueRange, in: noteText) else {
            let fallback = cues[index].text
            let wholeRange = fallback.startIndex..<fallback.endIndex
            return ActiveCueRenderInput(
                text: fallback,
                furiganaBySegmentLocation: [:],
                furiganaLengthBySegmentLocation: [:],
                segmentationRanges: fallback.isEmpty ? [] : [wholeRange]
            )
        }

        let cueText = String(noteText[swiftRange])
        let cueStart = cueRange.location
        let cueEnd = cueRange.location + cueRange.length

        // Furigana: keep entries whose kanji-run UTF-16 start sits inside the cue and
        // rebase the location to the cue substring's coords (so location 0 = first char).
        var rebasedFurigana: [Int: String] = [:]
        var rebasedFuriganaLength: [Int: Int] = [:]
        for (loc, reading) in furiganaBySegmentLocation where loc >= cueStart && loc < cueEnd {
            let rebased = loc - cueStart
            rebasedFurigana[rebased] = reading
            if let length = furiganaLengthBySegmentLocation[loc] {
                rebasedFuriganaLength[rebased] = length
            }
        }

        // One whole-cue segment for the active-cue card. We don't slice the parent's
        // `segmentationRanges` here because they're `Range<String.Index>` typed against
        // the parent's String state, which can race with `noteText` during note loads —
        // ANY index operation across two non-identical Strings is undefined in Swift and
        // traps inside StringUTF16View. The cue card is small enough that losing per-word
        // color alternation inside it is an acceptable trade for crash safety; the main
        // read view below still shows the full alternated rendering.
        let rebasedSegments: [Range<String.Index>] = cueText.isEmpty
            ? []
            : [cueText.startIndex..<cueText.endIndex]

        return ActiveCueRenderInput(
            text: cueText,
            furiganaBySegmentLocation: rebasedFurigana,
            furiganaLengthBySegmentLocation: rebasedFuriganaLength,
            segmentationRanges: rebasedSegments
        )
    }

    // Returns a font-size scale factor that fits `text` on a single line within
    // `availableWidth` at the given default font size. Clamped to [0.5, 1.0] so the cue
    // never shrinks below half its default — beyond that, clipping is preferable.
    private func activeCueFontScale(text: String, availableWidth: CGFloat) -> CGFloat {
        guard text.isEmpty == false, availableWidth > 0 else { return 1.0 }
        let baseFont = UIFont.systemFont(ofSize: TypographySettings.defaultTextSize)
        let measured = (text as NSString).size(withAttributes: [.font: baseFont]).width
        guard measured > availableWidth else { return 1.0 }
        return max(0.5, min(1.0, availableWidth / measured))
    }

    // Height for the active-cue card — sized to fit one visual line (ruby reserve at top
    // + body line + small bottom margin). Since the renderer now receives only the active
    // cue's text, this height bounds the card; the renderer's contentInset (topInset =
    // rubyReserve + 4) reserves space for ruby above the body line.
    private var activeCueRendererHeight: CGFloat {
        let textSize = TypographySettings.defaultTextSize
        let bodyHeight = UIFont.systemFont(ofSize: textSize).lineHeight
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        let rubyReserve = furiganaFont.lineHeight + CGFloat(TypographySettings.defaultFuriganaGap)
        // 4pt top inset + ruby reserve + body line + 4pt bottom margin matches the geometry
        // RenderGeometry produces with userLineSpacing=0.
        return rubyReserve + 4 + bodyHeight + 4
    }

    // Builds the main lyrics panel showing the scrollable cue history above the active-cue renderer.
    private func panel(geo: GeometryProxy) -> some View {
        let panelWidth = geo.size.width * 0.9
        let panelHeight = geo.size.height * 0.55
        let rendererHeight = activeCueRendererHeight
        let displayIndex = dragDisplayIndex ?? activeIndex

        // Clamp range upper bounds against lower bounds — `ForEach(a..<b)` traps when `b < a`,
        // and that can happen here when an audio note has zero cues (transcription returned
        // nothing, the .srt was empty) but `audioAttachmentID` is still set so this view
        // mounts. Without the clamps, opening such a note crashes during body evaluation.
        let aboveUpper = max(0, displayIndex)
        let belowLower = displayIndex + 1
        let belowUpper = max(belowLower, cues.count)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .center, spacing: 0) {
                        ForEach(0 ..< aboveUpper, id: \.self) { index in
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
                    guard cues.isEmpty == false else { return }
                    controller.seek(toMs: cues[max(0, activeIndex - 1)].startMs)
                }

                // Active cue renderer — fed ONLY the active cue's substring (with furigana
                // and clipped segmentation rebased to cue-local UTF-16 coords). The font is
                // scaled down when the cue is too wide for the card to keep it on a single
                // line, mirroring the inactive-cue scaling behavior.
                let cueInput = activeCueRenderInput(for: displayIndex)
                let cueOriginInNote: Int = (displayIndex < highlightRanges.count
                    ? highlightRanges[displayIndex]?.location : nil) ?? 0
                // Width budget: the panel's width minus the card's horizontal padding.
                // (Focus-card style adds 8pt each side; other styles 0pt — but inset 8pt of
                // safety margin so glyph edges don't kiss the card.)
                let activeCueAvailableWidth = panelWidth - 16
                let activeCueScale = activeCueFontScale(text: cueInput.text, availableWidth: activeCueAvailableWidth)
                let scaledTextSize = TypographySettings.defaultTextSize * Double(activeCueScale)
                VStack(spacing: 0) {
                    KiokuCoreTextRendererView(
                        text: cueInput.text,
                        segmentationRanges: cueInput.segmentationRanges,
                        furiganaBySegmentLocation: cueInput.furiganaBySegmentLocation,
                        furiganaLengthBySegmentLocation: cueInput.furiganaLengthBySegmentLocation,
                        isFuriganaVisible: true,
                        isVisualEnhancementsEnabled: true,
                        isColorAlternationEnabled: true,
                        textSize: Binding(get: { scaledTextSize }, set: { _ in }),
                        lineSpacing: 0,
                        kerning: 0,
                        furiganaGap: CGFloat(TypographySettings.defaultFuriganaGap),
                        evenSegmentColor: UIColor { tc in tc.userInterfaceStyle == .dark ? .systemOrange : .systemRed },
                        oddSegmentColor: UIColor { tc in tc.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo },
                        // Single-line render: scaling above keeps text within the card;
                        // disabling wrapping prevents any residual long cue from breaking
                        // onto a second visible line (it would clip instead).
                        isLineWrappingEnabled: false,
                        // Classic CT layout for the active-cue card — packing requires
                        // word-level segments which we no longer provide; clipped segments
                        // are fine for classic layout, which still alternates colors.
                        isRubySpacingEnabled: false,
                        selectedHighlightRange: nil,
                        playbackHighlightRange: nil,
                        selectionHighlightColor: .clear,
                        playbackHighlightColor: .clear,
                        unknownSegmentLocations: [],
                        isHighlightUnknownEnabled: false,
                        unknownSegmentColor: .label,
                        debugFlags: KiokuDebugOverlayView.Flags(),
                        illegalMergeLocation: nil,
                        onSegmentTapped: { localLocation, rect in
                            // Renderer hands back a cue-local UTF-16 location; translate to
                            // global noteText coords for parent consumers.
                            let globalLocation = localLocation.map { $0 + cueOriginInNote }
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
                        ForEach(belowLower ..< belowUpper, id: \.self) { index in
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
                    guard cues.isEmpty == false else { return }
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
                    guard cues.isEmpty == false else { return }
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
