import SwiftUI
import SwiftWhisperAlign
import Translation
import UIKit

// Floating karaoke-style lyrics popup rendered as an overlay on ReadView.
// Active cue is a persistent KiokuCoreTextRendererView fixed at center; inactive cues scroll past it.
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
    // The note's own id — used to look up a matching SongBreakdown (LyricsView+BreakdownGist)
    // so its per-line gist can be preferred over Apple's on-device translation. Nil-safe: no
    // breakdown lookup happens without it, falling back to translationCache as before.
    let noteID: UUID?
    // Narrowed playback highlight in noteText UTF-16 coords, computed upstream from the granularity
    // setting + cue timings. nil means no sub-cue highlight (Sentence behavior).
    let playbackHighlightRangeOverride: NSRange?
    // Current granularity setting, surfaced for the HUD. Per-cue checkpoints now ride on each cue
    // (cue.checkpoints) rather than a separate dictionary.
    let granularity: LyricsHighlightGranularity
    // A second, independent @AppStorage binding to the SAME key `granularity` reads (ReadView's
    // own @AppStorage, one level up) — `granularity` is a `let` so it can't be toggled from here;
    // this one can, and SwiftUI's @AppStorage instances sharing a key stay in sync automatically,
    // the same way SettingsView's Picker already does this independently. Backs the quick Word/
    // Sentence toggle in reAlignBar() — a faster path than Settings for something you're likely
    // to flip mid-listen while judging alignment quality.
    // Not private: reAlignBar() (LyricsView+ReAlignBar.swift) reads/writes it.
    @AppStorage(LyricsHighlightGranularity.storageKey) var quickGranularityRaw = LyricsHighlightGranularity.defaultValue.rawValue
    // Saved Highlight, in noteText UTF-16 coords — same signal as ReadView+Editor's
    // properties of the same name (resolved via resolvedDictionaryEntry(forSurface:), the
    // single canonical entry-ID resolution shared with the lookup sheet's button). Rebased to
    // cue-local coords at the render call site below, same as furiganaBySegmentLocation.
    // Defaulted so other call sites (previews) stay valid.
    var isSavedHighlightEnabled: Bool = false
    var savedSegmentLocations: Set<Int> = []
    var savedLearnedSegmentLocations: Set<Int> = []
    var savedNotLearnedSegmentLocations: Set<Int> = []
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    let onDismiss: () -> Void
    // Switches to Settings and scrolls to/highlights the named row (see SettingsView's
    // ScrollViewReader). Wired to the controls bar's gear button so a user wondering why
    // playback stopped in the background can jump straight to the Background Audio toggle.
    // Defaulted so previews/other call sites stay valid.
    var onFocusSetting: ((String) -> Void)? = nil
    // The top bar's Re-align action; ReadView owns the run. Defaulted so previews stay valid.
    var onReAlign: () -> Void = {}
    // True while a whole-song re-align is running, with `reAlignMessage` carrying the live
    // progress text. Drives the top bar's spinner + label.
    var isReAligning: Bool = false
    var reAlignMessage: String = ""

    // Horizontal fine-scrub sensitivity. 5 ms per point means a full ~300 pt swipe across the
    // card covers ~1.5 s — coarse enough to travel, fine enough to settle on a boundary.
    private let fineScrubMsPerPoint = 5.0

    // Not private: accessed from the LyricsView+Controls extension in a separate file.
    var activeIndex: Int { controller.activeCueIndex ?? 0 }

    // Clamped upper bound for seeks, in ms. Falls back generously when duration isn't known yet.
    var durationMs: Int {
        controller.duration > 0 ? Int(controller.duration * 1000) : Int.max
    }

    // Formats a millisecond position as M:SS.d (tenths) for the editing-row readouts, where
    // sub-second precision matters for judging a boundary.
    private func formatTenths(ms: Int) -> String {
        let totalTenths = max(0, ms) / 100
        let s = totalTenths / 10
        return String(format: "%d:%02d.%d", s / 60, s % 60, totalTenths % 10)
    }

    // Resolves the word (segment) under a cue-local tap/press location to its cue-local UTF-16
    // span and text, for the long-press timing menu. Returns nil when the location falls outside
    // every segment (e.g. trailing whitespace).
    private func wordSegment(at location: Int?, in cueInput: ActiveCueRenderInput) -> (offset: Int, length: Int, text: String)? {
        guard let location, cueInput.text.isEmpty == false else { return nil }
        for range in cueInput.segmentationRanges {
            let ns = NSRange(range, in: cueInput.text)
            guard ns.location != NSNotFound else { continue }
            if location >= ns.location && location < ns.location + ns.length {
                return (ns.location, ns.length, String(cueInput.text[range]))
            }
        }
        return nil
    }

    // Even/odd segment-alternation colors for the active-cue card. Honors the user's custom
    // palette when enabled, and otherwise resolves to the active theme's default token colors
    // (see ThemePalette). Kept in lockstep with ReadView+Editor's branching so the karaoke
    // card and the page render identically.
    private var resolvedEvenSegmentColor: UIColor {
        customTokenColorsEnabled
            ? (UIColor(hexString: tokenColorAHex) ?? .label)
            : (UIColor(hexString: Theme.activePalette.defaultTokenColorAHex) ?? .label)
    }

    private var resolvedOddSegmentColor: UIColor {
        customTokenColorsEnabled
            ? (UIColor(hexString: tokenColorBHex) ?? .secondaryLabel)
            : (UIColor(hexString: Theme.activePalette.defaultTokenColorBHex) ?? .secondaryLabel)
    }

    private var resolvedSavedHighlightColor: UIColor {
        UIColor(hexString: savedHex) ?? .systemYellow
    }

    private var resolvedSavedLearnedHighlightColor: UIColor {
        UIColor(hexString: savedLearnedHex) ?? .systemGreen
    }

    private var resolvedSavedNotLearnedHighlightColor: UIColor {
        UIColor(hexString: savedNotLearnedHex) ?? .systemPurple
    }

    // Active-word highlight, fixed (not theme/appearance-dependent): a solid amber pill with a
    // near-black foreground override, ~13:1 contrast. Previously the highlight recolored only
    // the *background* (a translucent gray, `UIColor.label.withAlphaComponent(0.32)`) while the
    // glyph kept whatever semantic token color it already had — red-on-light-gray landed at
    // ~2:1, worst on the red vocab words most worth reading. Ties into the scrubber's existing
    // `.systemOrange` tint (LyricsView+Controls) to read as "now playing" without being the
    // exact same (dynamic, appearance-dependent) color — this pill needs to guarantee its own
    // contrast against a fixed foreground regardless of light/dark mode.
    private static let activeWordHighlightColor = UIColor(hexString: "#FFCC66")!
    private static let activeWordForegroundColor = UIColor(hexString: "#1A1A1A")!

    // Played-portion band: marks "already sung" text as the playhead advances through the
    // active line. A background highlight, not a foreground-color fade — see
    // KiokuCoreTextRendererView's unplayedDimmingColor doc comment for why a fade doesn't
    // survive later foreground-color passes (the purple/green Saved Highlight bug). Low-alpha
    // `.label` is theme-adaptive (dark wash in light mode, light wash in dark mode) and reads
    // as a subtle "done" marker without competing with the amber active-word pill it sits under.
    private static let playedLineHighlightColor = UIColor.label.withAlphaComponent(0.10)

    // Number of cues where the subtitle text differs from the corresponding note text.
    private var mismatchCount: Int {
        cues.indices.filter { hasMismatch(at: $0) }.count
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
    func hasMismatch(at index: Int) -> Bool {
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
    // Not private: $isScrubbing is passed to LyricsScrubber in the LyricsView+Controls extension.
    @State var isScrubbing = false
    // Drag-axis lock for the panel gesture: vertical jumps cue-by-cue (coarse line nav),
    // horizontal fine-scrubs the playhead (granular). Decided once when the drag first
    // exceeds the minimum distance, then held for the rest of that drag so a wobbly finger
    // can't flip modes mid-gesture. nil between drags.
    @State private var dragAxis: Axis? = nil
    // Playhead time (ms) captured at the start of a horizontal fine-scrub, so the seek maps
    // the cumulative translation onto an absolute time rather than integrating per-frame.
    @State private var fineScrubBaseMs: Int? = nil

    @State private var translationTrigger: TranslationSession.Configuration? = nil
    // Supplies the note's SongBreakdown (if any) for LyricsView+BreakdownGist's gist lookup.
    // Auto-injected from the ancestor tree (ContentView) — no manual threading needed. Not
    // `private`: accessed from the LyricsView+BreakdownGist extension in a separate file.
    @EnvironmentObject var songBreakdownStore: SongBreakdownStore
    // Reads the same Read-view setting so toggling ruby spacing in Read also affects the
    // karaoke popup. AppStorage subscribes to the persisted key directly — no observation
    // plumbing needed for cross-view reactivity.
    @AppStorage(TypographySettings.rubySpacingKey) private var isRubySpacingEnabled = true
    // Mirror the Read-view custom segment-color settings so the active-cue card uses the same
    // palette the rest of Read does. Without these the card hardcoded the system defaults and
    // ignored the user's picks. AppStorage subscribes to the persisted keys directly.
    @AppStorage(TokenColorSettings.enabledKey) private var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage(TokenColorSettings.highlightColorKey) private var highlightHex: String = TokenColorSettings.defaultHighlightHex
    // Mirrors ReadView's Saved Highlight color pickers so the active-cue card tints
    // Save/Learned/Not Learned identically to the Read tab.
    @AppStorage(TokenColorSettings.savedColorKey) private var savedHex: String = TokenColorSettings.defaultSavedHex
    @AppStorage(TokenColorSettings.savedLearnedColorKey) private var savedLearnedHex: String = TokenColorSettings.defaultSavedLearnedHex
    @AppStorage(TokenColorSettings.savedNotLearnedColorKey) private var savedNotLearnedHex: String = TokenColorSettings.defaultSavedNotLearnedHex
    @StateObject var translationCache = LyricsTranslationCache()

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

    // Builds the main lyrics panel showing the scrollable cue history above the active-cue renderer.
    private func panel(geo: GeometryProxy) -> some View {
        let panelWidth = geo.size.width * 0.9
        let panelHeight = geo.size.height * 0.55
        let rendererHeight = activeCueRendererHeight
        // The cue shown on the active card (and the scroller split point). ♪/♫ instrumental-gap
        // cues are first-class rows — during an intro/gap the active card simply shows the ♪ cue,
        // and the scroller shows the ♪ rows approaching and receding like any other line.
        // Otherwise it tracks the live drag, then the playing line.
        let displayIndex = dragDisplayIndex ?? activeIndex

        // Clamp range upper bounds against lower bounds — `ForEach(a..<b)` traps when `b < a`,
        // and that can happen here when an audio note has zero cues (transcription returned
        // nothing, the .srt was empty) but `audioAttachmentID` is still set so this view
        // mounts. Without the clamps, opening such a note crashes during body evaluation.
        // Music-note pulsing during instrumental gaps was removed; the active card always
        // shows the cue at `displayIndex` (which during a gap is the upcoming vocal line —
        // the user just sees the next line waiting). belowLower is therefore always
        // displayIndex+1 (the active card occupies displayIndex itself).
        let aboveUpper = max(0, displayIndex)
        let belowLower = displayIndex + 1
        let belowUpper = max(belowLower, cues.count)
        return VStack(spacing: 0) {
            reAlignBar()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .center, spacing: 0) {
                        // Render every cue as a row regardless of whether the SRT marked it
                        // non-speech (♪/♫/empty). Instrumental gaps appear as `♪` rows that
                        // scroll past with the same distance-based fall-off as vocal cues —
                        // a visible "this section is instrumental" marker the user can see
                        // approaching (above the active card) and receding (below it), just
                        // like any other line. The dedicated `musicNoteSeparator` UI was
                        // removed earlier; this path uses the cue's own text ("♪") in the
                        // standard `inactiveCueRow` so non-speech cues participate in the
                        // scroller as first-class peers, not as special widgets.
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
                let untimedLocations: Set<Int> = []
                VStack(spacing: 0) {
                    // Pulsing ♪ during instrumental gaps was removed at user request.
                    // The active card now always shows the cue at `displayIndex` — during
                    // intros/gaps that means the *upcoming* cue is visible, which is fine
                    // and matches "see lyrics backwards and forwards regardless of play state."
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
                        evenSegmentColor: resolvedEvenSegmentColor,
                        oddSegmentColor: resolvedOddSegmentColor,
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
                        playbackHighlightColor: Self.activeWordHighlightColor,
                        // The played-portion band is gated on alignment-coverage: when
                        // forced-alignment checkpoints don't reach near the cue end, we pass
                        // nil (renderer shows no band at all) rather than freezing the band's
                        // trailing edge mid-line. The active-word pill still moves — only the
                        // "already sung" band disappears for low-coverage cues. See
                        // `cueHasReliableDimCoverage` for the 90%-of-cueLen threshold and its
                        // rationale.
                        unplayedDimmingLocation: cueHasReliableDimCoverage(forCueAtIndex: displayIndex, cueLength: cueInput.text.utf16.count)
                            ? cueLocalPlaybackHighlightRange(cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count).map { $0.location + $0.length }
                            : nil,
                        unplayedDimmingColor: Self.playedLineHighlightColor,
                        unknownSegmentLocations: untimedLocations,
                        isHighlightUnknownEnabled: false,
                        unknownSegmentColor: .tertiaryLabel,
                        isSavedHighlightEnabled: isSavedHighlightEnabled,
                        savedSegmentLocations: rebaseIntoCue(savedSegmentLocations, cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count),
                        savedHighlightColor: resolvedSavedHighlightColor,
                        savedLearnedSegmentLocations: rebaseIntoCue(savedLearnedSegmentLocations, cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count),
                        savedLearnedHighlightColor: resolvedSavedLearnedHighlightColor,
                        savedNotLearnedSegmentLocations: rebaseIntoCue(savedNotLearnedSegmentLocations, cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count),
                        savedNotLearnedHighlightColor: resolvedSavedNotLearnedHighlightColor,
                        // Overrides the highlighted range's glyph color so it never has to
                        // compete with whatever semantic token color (red vocab, blue, etc.)
                        // it already had — see activeWordForegroundColor's doc comment above.
                        accentTextRange: cueLocalPlaybackHighlightRange(cueOriginInNote: cueOriginInNote, cueLength: cueInput.text.utf16.count),
                        accentTextColor: Self.activeWordForegroundColor,
                        debugFlags: KiokuDebugOverlayView.Flags(),
                        illegalMergeLocation: nil,
                        onSegmentTapped: { localLocation, rect, _ in
                            // In the karaoke card a plain tap opens the dictionary lookup sheet —
                            // mirrors the Read tab so the tap-to-define mental model holds across
                            // both views. Word-level seek-to-tap moves to the long-press menu;
                            // cue-level seek (tap an inactive cue) and the scrubber are unchanged.
                            let globalLocation = localLocation.map { $0 + cueOriginInNote }
                            onSegmentTapped(globalLocation, rect, nil)
                        },
                        isScrollEnabled: false,
                        textAlignment: .center
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: rendererHeight)
                    .clipped()
                    if let translation = displayedTranslation(for: displayIndex) {
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
                .translationTask(translationTrigger) { session in
                    // Batch-translate all untranslated cues up front so translations are ready during playback.
                    await translateAllCues(session: session)
                }
                .onAppear {
                    translationTrigger = translationConfig
                }

                ScrollView {
                    VStack(alignment: .center, spacing: 0) {
                        // Render every cue as a row, including non-speech (♪/♫/empty) —
                        // see the above-scroll comment for the rationale.
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
                    guard cues.isEmpty == false else { return }
                    // Lock the axis on the first qualifying movement: a mostly-horizontal drag
                    // fine-scrubs the playhead (granular), a mostly-vertical drag jumps lines
                    // (coarse). Held for the rest of the gesture so the mode can't flip.
                    if dragAxis == nil {
                        // Favor vertical line-nav (the established gesture). Only commit to
                        // horizontal fine-scrub when the drag is CLEARLY horizontal, so a
                        // slightly-diagonal line drag isn't stolen into a scrub (which would
                        // move the playhead and make the line appear to rebound).
                        let w = abs(value.translation.width)
                        let h = abs(value.translation.height)
                        if w > h * 1.5 {
                            dragAxis = .horizontal
                            fineScrubBaseMs = controller.currentTimeMs
                        } else {
                            dragAxis = .vertical
                            isDragging = true
                            dragStartIndex = activeIndex
                        }
                    }

                    if dragAxis == .horizontal {
                        // Map cumulative horizontal travel onto an absolute seek from where the
                        // scrub began. Drag right → later in the song, left → earlier.
                        let base = fineScrubBaseMs ?? controller.currentTimeMs
                        let delta = Int(value.translation.width * fineScrubMsPerPoint)
                        controller.seek(toMs: max(0, min(durationMs, base + delta)))
                    } else {
                        let steps = Int(-value.translation.height / rendererHeight)
                        let raw = dragStartIndex + steps
                        dragOverscrolledToStart = raw < 0
                        dragDisplayIndex = min(cues.count - 1, max(0, raw))
                    }
                }
                .onEnded { _ in
                    // Horizontal scrub already seeked live; nothing to commit on release.
                    if dragAxis == .vertical {
                        if dragOverscrolledToStart {
                            controller.seek(toMs: 0)
                        } else if let target = dragDisplayIndex {
                            controller.seek(toMs: cues[target].startMs)
                        }
                    }
                    isDragging = false
                    dragDisplayIndex = nil
                    dragOverscrolledToStart = false
                    dragAxis = nil
                    fineScrubBaseMs = nil
                }
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
        .onAppear {
            if let attachmentID { translationCache.load(for: attachmentID) }
        }
    }

    // Returns the cue's raw SRT text — what the singer actually sang at that timecode.
    // Used for inactive rows and translation. We deliberately do NOT slice noteText with the
    // resolver's highlight range here: when the resolver overshoots a line boundary (off-by-N
    // alignment artefacts) the slice bleeds into the next song line and inactive rows show
    // fragmented mid-line text. The SRT is the source of truth for "what line was this," so
    // we use cue.text directly. The active-cue card still does its own noteText slicing for
    // furigana via `activeCueRenderInput`.
    func displayText(for cueIndex: Int) -> String {
        cueIndex < cues.count ? cues[cueIndex].text : ""
    }

    // Compact m:ss.mmm for the timing bar.
    func compactMs(_ ms: Int) -> String {
        let clamped = max(0, ms)
        return String(format: "%d:%02d.%03d", clamped / 60_000, (clamped / 1000) % 60, clamped % 1000)
    }

    // reAlignBar lives in LyricsView+ReAlignBar.swift;
    // controls (bottom transport bar) and LyricsScrubber moved to LyricsView+Controls.swift
    // to keep this file under the repo's line-count cap.

}

