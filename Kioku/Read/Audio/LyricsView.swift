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
    // Narrowed playback highlight in noteText UTF-16 coords, computed upstream from the granularity
    // setting + cue timings. nil means no sub-cue highlight (Sentence behavior).
    let playbackHighlightRangeOverride: NSRange?
    // TextGrid-derived per-cue checkpoints, surfaced here so the on-screen debug HUD can show
    // whether the active cue has karaoke data without requiring console log inspection.
    let cueTimings: CueCharTimings
    // Current granularity setting, surfaced for the HUD.
    let granularity: LyricsHighlightGranularity
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    let onDismiss: () -> Void

    private var activeIndex: Int { controller.activeCueIndex ?? 0 }

    // Number of cues where the subtitle text differs from the corresponding note text.
    private var mismatchCount: Int {
        cues.indices.filter { hasMismatch(at: $0) }.count
    }

    // Builds the live-state HUD shown at the top of the lyrics popup so the user can see what
    // the karaoke pipeline is doing. Kept terse — every field is one short token.
    private var karaokeDebugHUDText: String {
        let cueIdx = controller.activeCueIndex ?? -1
        let lookupKey: Int? = (cueIdx >= 0 && cueIdx < cues.count) ? cues[cueIdx].index : nil
        let cpCount = lookupKey.flatMap { cueTimings[$0]?.count } ?? 0
        let totalKeys = cueTimings.count
        let overrideText: String = {
            guard let r = playbackHighlightRangeOverride else { return "nil" }
            return "[\(r.location),\(r.length)]"
        }()
        let highlightRangeText: String = {
            guard cueIdx >= 0, cueIdx < highlightRanges.count else { return "?" }
            guard let r = highlightRanges[cueIdx] else { return "nil" }
            return "[\(r.location),\(r.length)]"
        }()
        let cueLen: Int = {
            guard cueIdx >= 0, cueIdx < cues.count else { return 0 }
            return cues[cueIdx].text.utf16.count
        }()
        let t = controller.currentTimeMs
        let p0 = cueTextPreview(at: cueIdx - 1)
        let p1 = cueTextPreview(at: cueIdx)
        let p2 = cueTextPreview(at: cueIdx + 1)
        let p3 = cueTextPreview(at: cueIdx + 2)
        let neighborText = "[\(p0) | \(p1) | \(p2) | \(p3)]"
        return "g=\(granularity.rawValue) cue=\(cueIdx) key=\(lookupKey.map(String.init) ?? "-") cp=\(cpCount) total=\(totalKeys) hr=\(highlightRangeText) cueLen=\(cueLen) ovr=\(overrideText) t=\(t) \(neighborText)"
    }

    // Returns a short preview of the cue text at the given index for the HUD's neighbor strip.
    // Returns "-" when the index is out of range, and collapses internal newlines so a multi-
    // line cue still fits on one HUD line.
    private func cueTextPreview(at index: Int) -> String {
        guard index >= 0, index < cues.count else { return "-" }
        let s = cues[index].text.replacingOccurrences(of: "\n", with: "/")
        return String(s.prefix(8))
    }

    // Rebases the noteText-coord override range to cue-local UTF-16 coords for the active-cue
    // renderer. Returns nil when the override is nil (Sentence behavior) or when the range doesn't
    // intersect this cue (cue boundary edge case). Clamps to the cue length so renderer never
    // receives an out-of-bounds NSRange.
    private func cueLocalPlaybackHighlightRange(cueOriginInNote: Int, cueLength: Int) -> NSRange? {
        guard let override = playbackHighlightRangeOverride else { return nil }
        let overrideEnd = override.location + override.length
        let cueEnd = cueOriginInNote + cueLength
        let clampedStart = max(override.location, cueOriginInNote)
        let clampedEnd = min(overrideEnd, cueEnd)
        guard clampedEnd > clampedStart else { return nil }
        return NSRange(
            location: clampedStart - cueOriginInNote,
            length: clampedEnd - clampedStart
        )
    }

    // Decides whether the forced-alignment checkpoints for the cue at `displayIndex`
    // cover the line densely enough that dimming the unplayed tail can be done
    // reliably. Returns false (= suppress dim, show whole line at full alpha) when
    // checkpoints are missing or the latest checkpoint stops well short of the cue
    // end — in that case the band would otherwise freeze at a midpoint and chars
    // past it would read as "unplayed" even though they're being sung right now.
    //
    // The 90% threshold is intentionally generous: forced alignment that genuinely
    // covers the line lands with the last checkpoint within a couple characters of
    // cue end (the last word's begin/end). Anything below 90% means we're missing
    // the tail, and "no dim" is a more honest UI than a stuck dim line.
    //
    // Why suppression over linear interpolation: with sparse checkpoints the
    // alignment data itself can't be trusted to localize a frontier, so a clock-
    // based estimate would be guessing. Showing the whole line is the only honest
    // option until alignment improves. Sentence-granularity cues already have
    // override.upperBound == cueLength so they short-circuit this anyway.
    private func cueHasReliableDimCoverage(forCueAtIndex displayIndex: Int, cueLength: Int) -> Bool {
        guard displayIndex >= 0, displayIndex < cues.count, cueLength > 0 else { return false }
        // Use the cue's `.index` field (its original SRT/numeric ID) as the timings
        // dict key, matching the lookup convention in the karaokeDebugHUDText and the
        // observer — array position alone would desync after a skipped/malformed cue.
        let key = cues[displayIndex].index
        guard let checkpoints = cueTimings[key], checkpoints.isEmpty == false else { return false }
        let maxEnd = checkpoints.map { $0.charOffsetInCue + $0.charLength }.max() ?? 0
        return Double(maxEnd) >= Double(cueLength) * 0.9
    }

    // Returns the slice of noteText that the resolver mapped to this cue, if any.
    // Used only for mismatch detection — `displayText(for:)` deliberately returns the
    // raw cue text now to avoid bleeding past line boundaries on resolver overshoot,
    // but mismatch detection still needs the resolver-mapped note range to know
    // whether the cue text differs from what the note says at that timecode.
    private func noteTextForCue(at index: Int) -> String? {
        guard index < highlightRanges.count,
              let range = highlightRanges[index],
              let swiftRange = Range(range, in: noteText) else {
            return nil
        }
        return String(noteText[swiftRange])
    }

    // Returns true when the cue text doesn't match the resolver-mapped note text for this
    // index. Compares against the noteText slice — NOT `displayText(for:)`, which now
    // returns the raw cue text and would always compare equal to itself, suppressing the
    // orange-dot mismatch indicator that flags resolver-vs-cue divergence.
    private func hasMismatch(at index: Int) -> Bool {
        guard let note = noteTextForCue(at: index) else { return false }
        let cue = cues[index].text
        // Cosmetic whitespace/newline differences (e.g. SRT cue is single-line but the
        // matched note line has a trailing newline, or the cue carries an internal break
        // the note doesn't) shouldn't fire the orange-dot indicator — that flag is for
        // textual divergence, not formatting. Collapse runs of whitespace on both sides
        // before comparing so only real content differences light it up.
        let normalize: (String) -> String = { text in
            text.components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        }
        return normalize(note) != normalize(cue)
            && SubtitleParser.isNonSpeechCue(cue.trimmingCharacters(in: .whitespacesAndNewlines)) == false
    }

    @State private var dragStartIndex: Int = 0
    @State private var dragDisplayIndex: Int? = nil
    @State private var isDragging: Bool = false
    @State private var dragOverscrolledToStart: Bool = false
    @State private var isScrubbing = false
    @State private var translationTrigger: TranslationSession.Configuration? = nil
    // Reads the same Read-view setting so toggling ruby spacing in Read also affects the
    // karaoke popup. AppStorage subscribes to the persisted key directly — no observation
    // plumbing needed for cross-view reactivity.
    @AppStorage("kioku.settings.rubySpacing") private var isRubySpacingEnabled = true
    // Settings → Debug → "Karaoke HUD" controls whether the diagnostic strip
    // overlays the active-cue card. Default off so the lyrics card reads clean;
    // the binding is read-only here since the toggle lives in SettingsView.
    @AppStorage(DebugSettings.karaokeDebugHUDKey) private var isKaraokeDebugHUDVisible: Bool = false
    @StateObject private var translationCache = LyricsTranslationCache()

    // Previously three variants (appleMusic / accentBar / focusCard) selectable from Settings.
    // Collapsed to one canonical style: centered text, no accent stripe, scale + opacity + blur
    // fall off with distance from the active cue.

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
            // Fallback path (non-speech cue, alignment unresolved): use the raw cue text
            // but still clip at the first newline so a multi-line SRT cue only shows the
            // first sung line in the active card — same single-line contract as the
            // resolved path below.
            let raw = cues[index].text
            let fallback = clipAtFirstNewline(raw)
            let wholeRange = fallback.startIndex..<fallback.endIndex
            return ActiveCueRenderInput(
                text: fallback,
                furiganaBySegmentLocation: [:],
                furiganaLengthBySegmentLocation: [:],
                segmentationRanges: fallback.isEmpty ? [] : [wholeRange]
            )
        }

        // Clip at the first newline. The resolver occasionally maps a cue to a noteText
        // range that crosses a line boundary (off-by-N alignment artifact, or a multi-line
        // note section paired with a single-line cue). Without this clip the active card
        // visibly bleeds the next song line in alongside the current one. cueEnd is
        // recomputed against the clipped UTF-16 length so segment/furigana filtering below
        // stays inside the visible slice.
        let rawCueSlice = String(noteText[swiftRange])
        let cueText = clipAtFirstNewline(rawCueSlice)
        let cueStart = cueRange.location
        let cueEnd = cueStart + cueText.utf16.count

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

        // Rebase parent segments into cue-local ranges via UTF-16 offsets, so we never
        // cross two String instances with String.Index (which traps in StringUTF16View).
        // Each parent range → NSRange against noteText → clip to [cueStart, cueEnd) →
        // shift by -cueStart → Range<String.Index> against cueText. Boundary-crossing
        // segments are clipped rather than dropped, so every character keeps its color.
        var rebasedSegments: [Range<String.Index>] = []
        if cueText.isEmpty == false {
            let noteNS = noteText as NSString
            for parentRange in segmentationRanges {
                let parentNS = NSRange(parentRange, in: noteText)
                guard parentNS.location != NSNotFound else { continue }
                let segStart = parentNS.location
                let segEnd = parentNS.location + parentNS.length
                let clippedStart = max(segStart, cueStart)
                let clippedEnd = min(segEnd, cueEnd)
                guard clippedEnd > clippedStart, clippedStart >= 0, clippedEnd <= noteNS.length else { continue }
                let localNS = NSRange(location: clippedStart - cueStart, length: clippedEnd - clippedStart)
                if let local = Range(localNS, in: cueText) {
                    rebasedSegments.append(local)
                }
            }
            if rebasedSegments.isEmpty {
                rebasedSegments = [cueText.startIndex..<cueText.endIndex]
            }
        }

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

    // Compact height for inactive cue rows and ♪ separators. Drops the ruby reserve since
    // inactive rows are plain Text (no furigana drawn), so reserving that vertical space
    // produces visibly large gaps between rows.
    private var inactiveCueRowHeight: CGFloat {
        let textSize = TypographySettings.defaultTextSize
        let bodyHeight = UIFont.systemFont(ofSize: textSize).lineHeight
        return bodyHeight + 4
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
        // When we're in a no-vocal stretch (intro, ♪ cue, instrumental gap), the active card
        // slot renders the pulsing ♪ and the activeCueIndex cue itself is the *upcoming*
        // vocal line — it hasn't started yet. Surface it in the below-scroll so the user can
        // see what's coming next instead of hiding cue 0 entirely during the intro.
        let inNoVocalStretch = noVocalStretchRemainingMs != nil
        let aboveUpper = max(0, displayIndex)
        let belowLower = inNoVocalStretch ? displayIndex : displayIndex + 1
        let belowUpper = max(belowLower, cues.count)
        return VStack(spacing: 0) {
            // Karaoke diagnostics HUD — only laid out when the user has flipped
            // Settings → Debug → "Karaoke HUD". `if`-gated rather than
            // `.opacity(0)` so it consumes no vertical space when off; otherwise
            // the active cue would still sit shifted down by the HUD's height.
            if isKaraokeDebugHUDVisible {
                Text(karaokeDebugHUDText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.4))
            }
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .center, spacing: 0) {
                        // Each cue from the source SRT renders as either a vocal row or a ♪
                        // separator based on its own text — we deliberately do NOT synthesize
                        // markers from inter-cue timing gaps. The subtitle/TextGrid files are
                        // already the source of truth for instrumental sections; gap-based
                        // heuristics either miss real interludes (threshold too high) or
                        // invent fake ones (threshold too low). Trust the data.
                        ForEach(0 ..< aboveUpper, id: \.self) { index in
                            let distance = displayIndex - index
                            if SubtitleParser.isNonSpeechCue(cues[index].text) {
                                musicNoteSeparator(distance: distance)
                            } else {
                                inactiveCueRow(index: index, distance: distance)
                            }
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
                // Use the same noteText probe activeCueRenderInput uses so the override rebase
                // lines up with the rendered cue position. If we used 0 here while the renderer
                // found the cue at noteText offset N, the observer's override (in real noteText
                // coords) wouldn't overlap with the cue's synthetic [0, length) and rebase
                // would return nil — no band visible.
                let cueOriginInNote: Int = {
                    if displayIndex < highlightRanges.count, let r = highlightRanges[displayIndex] {
                        return r.location
                    }
                    let cueText = displayIndex < cues.count ? cues[displayIndex].text : ""
                    if cueText.isEmpty == false {
                        let probe = (noteText as NSString).range(of: cueText)
                        if probe.location != NSNotFound { return probe.location }
                    }
                    return 0
                }()
                // Width budget: the panel's width minus the card's horizontal padding.
                // (Focus-card style adds 8pt each side; other styles 0pt — but inset 8pt of
                // safety margin so glyph edges don't kiss the card.)
                let activeCueAvailableWidth = panelWidth - 16
                let activeCueScale = activeCueFontScale(text: cueInput.text, availableWidth: activeCueAvailableWidth)
                let scaledTextSize = TypographySettings.defaultTextSize * Double(activeCueScale)
                VStack(spacing: 0) {
                    if noVocalStretchRemainingMs != nil {
                        PulsingDotsIndicator(controller: controller)
                            .frame(maxWidth: .infinity)
                            .frame(height: rendererHeight)
                    } else {
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
                        // Honor the Read-view ruby-spacing toggle so wide furigana doesn't
                        // crash into adjacent kanji in the active-cue card. Packed-layout
                        // requirements (word-level segments) are satisfied here because the
                        // segments come from the same noteText segmentation the Read view uses.
                        isRubySpacingEnabled: isRubySpacingEnabled,
                        selectedHighlightRange: nil,
                        playbackHighlightRange: cueLocalPlaybackHighlightRange(cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count),
                        selectionHighlightColor: .clear,
                        playbackHighlightColor: UIColor.label.withAlphaComponent(0.32),
                        // Dim is gated on alignment-coverage: when forced-alignment
                        // checkpoints don't reach near the cue end, we pass nil
                        // (renderer leaves the whole line at full alpha) rather than
                        // freezing the dim frontier mid-line. The active band still
                        // moves — only the "unplayed tail" visual disappears for
                        // low-coverage cues. See `cueHasReliableDimCoverage` for the
                        // 90%-of-cueLen threshold and its rationale.
                        unplayedDimmingLocation: cueHasReliableDimCoverage(forCueAtIndex: displayIndex, cueLength: cueInput.text.utf16.count)
                            ? cueLocalPlaybackHighlightRange(cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count).map { $0.location + $0.length }
                            : nil,
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
                    if let translation = translationCache.translations[displayText(for: displayIndex)] {
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
                    } // end else (vocal-cue rendering)
                }
                .padding(.vertical, 8)
                .translationTask(translationTrigger) { session in
                    // Batch-translate all untranslated cues up front so translations are ready during playback.
                    await translateAllCues(session: session)
                }
                .onAppear {
                    translationTrigger = translationConfig
                }

                ScrollView {
                    VStack(alignment: .center, spacing: 0) {
                        // Same data-driven contract as the above-scroll: render whatever the
                        // SRT emits, don't synthesize ♪ markers from timing gaps.
                        ForEach(belowLower ..< belowUpper, id: \.self) { index in
                            let distance = index - displayIndex
                            if SubtitleParser.isNonSpeechCue(cues[index].text) {
                                musicNoteSeparator(distance: distance)
                            } else {
                                inactiveCueRow(index: index, distance: distance)
                            }
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
    // Single canonical inactive-cue row: centered text that scales, fades, and blurs further from
    // the active cue. Mismatch indicator (orange dot) survives because it conveys data, not style.
    @ViewBuilder
    private func inactiveCueRow(index: Int, distance: Int) -> some View {
        let metrics = inactiveCueMetrics(distance: distance)
        let defaultSize = CGFloat(TypographySettings.defaultTextSize)
        let text = displayText(for: index)
        let scaleFactor = distance == 0 ? scaleFactorForActiveCue(text: text, availableWidth: 280, defaultFontSize: defaultSize) : 1.0
        let fontSize = defaultSize * scaleFactor

        HStack(spacing: 4) {
            if hasMismatch(at: index) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: fontSize, weight: .regular))
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: inactiveCueRowHeight)
        .padding(.horizontal, 16)
        .scaleEffect(metrics.scale, anchor: .center)
        .opacity(metrics.opacity)
        .blur(radius: metrics.blur)
    }

    // Renders a ♪ separator row inserted between vocal cues where the audio has a long
    // instrumental gap. Same height and distance-based scale/opacity as inactive cue rows so
    // the marker reads as a peer entry in the list rather than a compressed delimiter.
    @ViewBuilder
    private func musicNoteSeparator(distance: Int) -> some View {
        let metrics = inactiveCueMetrics(distance: distance)
        Text("♪")
            .font(.system(size: CGFloat(TypographySettings.defaultTextSize), weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: inactiveCueRowHeight)
            .scaleEffect(metrics.scale, anchor: .center)
            .opacity(metrics.opacity)
    }

    // Apple Music-style fall-off: closer rows are larger and brighter, distant rows shrink
    // and fade. No blur — the size+opacity wave is the readable cue without softening text
    // into mush.
    private func inactiveCueMetrics(distance: Int) -> (scale: Double, opacity: Double, blur: Double) {
        return (
            scale: max(0.62, 1.0 - Double(distance) * 0.10),
            opacity: max(0.28, 1.0 - Double(distance) * 0.16),
            blur: 0
        )
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
            guard translationCache.needsTranslation(text: text) else { continue }
            do {
                let response = try await session.translate(text)
                await MainActor.run { translationCache.store(text: text, result: response.targetText) }
            } catch {
                // Individual cue failure is non-fatal — skip and continue.
            }
        }
    }

    // Returns ms remaining until the next vocal cue when the playhead is currently inside a
    // non-speech (♪) cue from the source SRT, OR sitting in the intro before the first
    // vocal cue. nil means a vocal cue is currently playing — render the regular active card.
    //
    // Data-driven: the source SRT/TextGrid marks instrumental sections as non-speech cues.
    // We don't synthesize "no-vocal" state from inter-cue gap timing — heuristic thresholds
    // either over-trigger (every routine line break flashes the pulsing dots) or under-trigger
    // (real interludes get missed). If the source files didn't bother marking a section, we
    // treat it as silence between vocal cues rather than as an interlude.
    private var noVocalStretchRemainingMs: Int? {
        guard cues.isEmpty == false else { return nil }
        let currentMs = controller.currentTimeMs
        let isVocal: (SubtitleCue) -> Bool = { !SubtitleParser.isNonSpeechCue($0.text) }
        guard let nextVocalCue = cues.first(where: { isVocal($0) && $0.startMs > currentMs }) else {
            return nil
        }
        // Inside a non-speech cue — show pulsing dots until the next vocal cue starts.
        if cues.contains(where: { !isVocal($0) && $0.startMs <= currentMs && currentMs < $0.endMs }) {
            return max(0, nextVocalCue.startMs - currentMs)
        }
        // Intro before the first cue of any kind.
        if let firstCue = cues.first, currentMs < firstCue.startMs {
            return max(0, nextVocalCue.startMs - currentMs)
        }
        return nil
    }

    // Returns the cue's raw SRT text — what the singer actually sang at that timecode.
    // Used for inactive rows and translation. We deliberately do NOT slice noteText with the
    // resolver's highlight range here: when the resolver overshoots a line boundary (off-by-N
    // alignment artefacts) the slice bleeds into the next song line and inactive rows show
    // fragmented mid-line text. The SRT is the source of truth for "what line was this," so
    // we use cue.text directly. The active-cue card still does its own noteText slicing for
    // furigana via `activeCueRenderInput`.
    private func displayText(for cueIndex: Int) -> String {
        cueIndex < cues.count ? cues[cueIndex].text : ""
    }

    // Returns `text` truncated at the first newline scalar (\n or \r), or the original
    // string when no newline is present. Used by the active-cue card to enforce a
    // single-song-line contract regardless of multi-line cue text or resolver overshoot.
    private func clipAtFirstNewline(_ text: String) -> String {
        if let idx = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(text[text.startIndex..<idx])
        }
        return text
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

