import SwiftUI
import SwiftWhisperAlign
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
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    let onDismiss: () -> Void
    // Switches to Settings and scrolls to/highlights the named row (see SettingsView's
    // ScrollViewReader). Wired to the controls bar's gear button so a user wondering why
    // playback stopped in the background can jump straight to the Background Audio toggle.
    // Defaulted so previews/other call sites stay valid.
    var onFocusSetting: ((String) -> Void)? = nil
    // In-place cue editing: the persistent top row emits an intent (set/nudge the start or end
    // boundary, or re-align the word sweep) for the cue currently on the active card. ReadView
    // owns persistence + controller refresh. Defaulted so previews/other call sites stay valid.
    var onCueEdit: (LyricCueEdit) -> Void = { _ in }
    // Cue index currently being re-aligned on device (Whisper running); the "Fix" button shows a
    // spinner for that cue and all edit buttons disable. nil when idle.
    var realigningCueIndex: Int? = nil
    // True while a FULL from-scratch re-align (whole note) is running, with `reAlignMessage`
    // carrying the live progress text. Drives the top Re-align bar's spinner + label.
    var isReAligning: Bool = false
    var reAlignMessage: String = ""
    // Whether an isolated vocal stem is cached for this audio (so playback can switch to it) and
    // the current toggle state. ReadView owns the state + the actual source swap; the bar just
    // shows the control and flips the binding. Defaulted off/unavailable for other call sites.
    var stemAvailable: Bool = false
    var isListeningToStem: Binding<Bool> = .constant(false)

    // Horizontal fine-scrub sensitivity. 5 ms per point means a full ~300 pt swipe across the
    // card covers ~1.5 s — coarse enough to travel, fine enough to settle on a boundary.
    private let fineScrubMsPerPoint = 5.0

    // Not private: accessed from the LyricsView+Controls extension in a separate file.
    var activeIndex: Int { controller.activeCueIndex ?? 0 }

    // Clamped upper bound for seeks, in ms. Falls back generously when duration isn't known yet.
    private var durationMs: Int {
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
    // (see Theme.Palette). Kept in lockstep with ReadView+Editor's branching so the karaoke
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
    // Alignment-adjust mode: reveals the per-line fix row and pins the card to a chosen target
    // line so the transport can move the playhead INDEPENDENTLY. A mistimed line isn't "active"
    // at the moment you want to assign it, so target and playhead must decouple — that decoupling
    // is the whole reason the old inline row felt broken. Default off so the card reads clean.
    @State private var isAdjustingAlignment = false
    // The line being retimed while adjusting (persists across scrubs); nil → fall back to the
    // playing line. Set by entering Adjust (→ the active line) or by dragging/tapping to pick.
    @State private var adjustTargetIndex: Int? = nil
    // Peak envelope for the Adjust waveform editor. Source follows the Vocals/Mix toggle: the
    // isolated vocal stem when "Vocals" is on (and a stem is cached), otherwise the full mix.
    // `waveformNoteID` and `waveformIsStem` record which note + source it belongs to so switching
    // notes OR flipping the toggle reloads it.
    @State private var waveform: WaveformEnvelope? = nil
    @State private var waveformNoteID: UUID? = nil
    @State private var waveformIsStem: Bool = false
    // Debug: raw ASR transcript of the vocal stem, for diagnosing mis-timed lines (does the aligner
    // actually "hear" a line where it belongs?). Triggered by a long-press on the timing readout;
    // shown in a copyable sheet. Not a shipping affordance.
    @State var stemTranscript: [SubtitleCue]?
    @State var isDumpingTranscript = false
    @State var transcriptStatus = ""
    @State var showTranscriptSheet = false
    // Long-press word context: when set, a confirmation dialog snaps the pressed word's START or
    // END timing to the playhead snapshot, plus dictionary look-up. nil = hidden.
    @State private var wordTimingMenu: WordTimingMenu? = nil

    // Captures everything the long-press timing menu needs about the word that was pressed.
    struct WordTimingMenu {
        let cueIndex: Int
        let playheadMs: Int       // playback position snapshotted at long-press
        let wordCharOffset: Int   // cue-local UTF-16 start of the pressed word
        let wordCharLength: Int
        let wordText: String      // for the menu's title/message
        let globalLocation: Int?  // noteText UTF-16 location, for routing to dictionary look-up
        let rect: CGRect?
    }
    @State private var translationTrigger: TranslationSession.Configuration? = nil
    // Supplies the note's SongBreakdown (if any) for LyricsView+BreakdownGist's gist lookup.
    // Auto-injected from the ancestor tree (ContentView) — no manual threading needed. Not
    // `private`: accessed from the LyricsView+BreakdownGist extension in a separate file.
    @EnvironmentObject var songBreakdownStore: SongBreakdownStore
    // Reads the same Read-view setting so toggling ruby spacing in Read also affects the
    // karaoke popup. AppStorage subscribes to the persisted key directly — no observation
    // plumbing needed for cross-view reactivity.
    @AppStorage("kioku.settings.rubySpacing") private var isRubySpacingEnabled = true
    // Mirror the Read-view custom segment-color settings so the active-cue card uses the same
    // palette the rest of Read does. Without these the card hardcoded the system defaults and
    // ignored the user's picks. AppStorage subscribes to the persisted keys directly.
    @AppStorage(TokenColorSettings.enabledKey) private var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    // Settings → Debug → "Karaoke HUD" controls whether the diagnostic strip
    // overlays the active-cue card. Default off so the lyrics card reads clean;
    // the binding is read-only here since the toggle lives in SettingsView.
    @AppStorage(DebugSettings.karaokeDebugHUDKey) private var isKaraokeDebugHUDVisible: Bool = false
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
        // In Adjust mode the card pins to the chosen target line (so the playhead can roam to a
        // mistimed line's real start without the card following it); otherwise it tracks the live
        // drag, then the playing line.
        let displayIndex = dragDisplayIndex
            ?? (isAdjustingAlignment ? adjustTargetIndex : nil)
            ?? activeIndex

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
            // Top action row. Replaced the per-cue timing-editor row (Set Start / playhead /
            // Set End / Fix word sweep) with a single full Re-align action — re-runs the whole
            // CTC pipeline on the attached audio. The old row is preserved (commented) below and
            // `cueEditingRow(index:)` is kept defined for a one-line revert.
            reAlignBar()
            cueTimingBar(index: displayIndex)
            // The per-line alignment-fix row only appears in Adjust mode (toggled in reAlignBar),
            // so normal listening stays clean. It targets `displayIndex` — which in Adjust mode is
            // the pinned target line, not the playing line.
            if isAdjustingAlignment, cues.isEmpty == false {
                alignmentFixRow(index: displayIndex)
            }
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
                    if isAdjustingAlignment {
                        // Step the target line up one (no seek) so you can retarget without losing
                        // the playhead position you set.
                        adjustTargetIndex = max(0, (adjustTargetIndex ?? activeIndex) - 1)
                    } else {
                        controller.seek(toMs: cues[max(0, activeIndex - 1)].startMs)
                    }
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
                        unknownSegmentLocations: untimedLocations,
                        isHighlightUnknownEnabled: false,
                        unknownSegmentColor: .tertiaryLabel,
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
                        onSegmentLongPressed: { localLocation, rect, _ in
                            // Long-press opens a menu for the pressed WORD: snap its start or end
                            // to the playhead (captured now), or look it up. The word's cue-local
                            // char span comes from the segment under the press.
                            let globalLocation = localLocation.map { $0 + cueOriginInNote }
                            let segment = wordSegment(at: localLocation, in: cueInput)
                            wordTimingMenu = WordTimingMenu(
                                cueIndex: displayIndex,
                                playheadMs: controller.currentTimeMs,
                                wordCharOffset: segment?.offset ?? 0,
                                wordCharLength: segment?.length ?? 0,
                                wordText: segment?.text ?? "",
                                globalLocation: globalLocation,
                                rect: rect
                            )
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
                    if isAdjustingAlignment {
                        // Step the target line down one (no seek), mirroring the upper tap zone.
                        adjustTargetIndex = min(cues.count - 1, (adjustTargetIndex ?? activeIndex) + 1)
                    } else {
                        controller.seek(toMs: cues[min(cues.count - 1, activeIndex + 1)].startMs)
                    }
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
                        if isAdjustingAlignment {
                            // Adjust mode: a vertical drag PICKS the target line — no seek, so the
                            // playhead stays where you parked it to hear the real start.
                            if let target = dragDisplayIndex { adjustTargetIndex = target }
                        } else if dragOverscrolledToStart {
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
        .confirmationDialog(
            wordTimingMenu?.wordText.isEmpty == false ? "“\(wordTimingMenu!.wordText)”" : "Word timing",
            isPresented: Binding(
                get: { wordTimingMenu != nil },
                set: { presented in if presented == false { wordTimingMenu = nil } }
            ),
            presenting: wordTimingMenu
        ) { menu in
            Button("This word starts at \(formatTenths(ms: menu.playheadMs))") {
                onCueEdit(.setWordStartToPlayhead(
                    cueIndex: menu.cueIndex, charOffset: menu.wordCharOffset,
                    charLength: menu.wordCharLength, ms: menu.playheadMs
                ))
            }
            Button("This word ends at \(formatTenths(ms: menu.playheadMs))") {
                onCueEdit(.setWordEndToPlayhead(
                    cueIndex: menu.cueIndex, charOffset: menu.wordCharOffset,
                    charLength: menu.wordCharLength, ms: menu.playheadMs
                ))
            }
            Button("Look up word") {
                onSegmentTapped(menu.globalLocation, menu.rect, nil)
            }
            Button("Cancel", role: .cancel) { }
        } message: { menu in
            Text("Snap this word's start or end to the current playback position (\(formatTenths(ms: menu.playheadMs))). Scrub or pause to the right moment first.")
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

    // Timing readout under the Re-align/Adjust/Mix row: just the shown card's cue start → end,
    // centered and subdued. The transport already shows the live playhead, so it isn't repeated here.
    // Long-press dumps the vocal-stem ASR transcript (debug) to compare against the aligned timing.
    @ViewBuilder
    private func cueTimingBar(index: Int) -> some View {
        Group {
            if isDumpingTranscript {
                Text(transcriptStatus.isEmpty ? "Transcribing vocals…" : transcriptStatus)
                    .font(.system(size: 12, weight: .medium))
            } else if index >= 0, index < cues.count {
                let cue = cues[index]
                Text("\(compactMs(cue.startMs))  →  \(compactMs(cue.endMs))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onLongPressGesture { dumpStemTranscript() }
        .sheet(isPresented: $showTranscriptSheet) { transcriptSheet }
    }

    // Top action bar for the karaoke view: a single full Re-align action that re-runs the whole
    // CTC alignment pipeline (vocal separation + windowing) over the note's lyrics against the
    // attached audio — no wipe / re-import. Replaces the old per-cue timing-editor row. While
    // running it shows a spinner + live progress and disables so a second run can't stack.
    private func reAlignBar() -> some View {
        HStack(spacing: 8) {
            if isReAligning {
                // Live progress is its OWN non-interactive chip, not the disabled Button's
                // label — a disabled Button dims its whole label, which made the status text
                // read as greyed-out/inactive. `.primary` keeps it high-contrast over the bar.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(reAlignMessage.isEmpty ? "Re-aligning…" : reAlignMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.16))
                .clipShape(Capsule())
                .accessibilityLabel(reAlignMessage.isEmpty ? "Re-aligning" : reAlignMessage)
            } else {
                Button {
                    onCueEdit(.realignAll)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Re-align")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Re-align all lyrics to the audio")
            }

            // Adjust toggle: reveal the per-line alignment-fix row. Off keeps the card clean while
            // listening; on, the card pins to the target line and the transport moves the playhead
            // independently so you can set a line's true start. Entering Adjust seeds the target
            // with the line currently playing.
            Button {
                isAdjustingAlignment.toggle()
                adjustTargetIndex = isAdjustingAlignment ? activeIndex : nil
            } label: {
                let on = isAdjustingAlignment
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Adjust")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background((on ? Color.accentColor : Color.secondary).opacity(0.16))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(cues.isEmpty)
            .accessibilityLabel(isAdjustingAlignment ? "Hide alignment adjust controls" : "Show alignment adjust controls")

            // Stem-listen toggle: swap playback between the original mix and the isolated vocal
            // stem (what the aligner hears). Shown only when a stem is cached for this audio — i.e.
            // after a Re-align — and hidden while a re-align is in flight (the stem may be mid-
            // regeneration). ReadView's onChange does the position-preserving source swap.
            if stemAvailable && isReAligning == false {
                Button {
                    isListeningToStem.wrappedValue.toggle()
                } label: {
                    let on = isListeningToStem.wrappedValue
                    HStack(spacing: 6) {
                        Image(systemName: on ? "waveform.circle.fill" : "waveform.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text(on ? "Vocals" : "Mix")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((on ? Color.accentColor : Color.secondary).opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListeningToStem.wrappedValue
                    ? "Playing isolated vocals. Tap to hear the original mix."
                    : "Playing original mix. Tap to hear the isolated vocals.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.18))
    }

    // Per-line alignment editor (Adjust mode only): a draggable waveform for the targeted line plus
    // ▲▼ retarget, "+ shift rest" section ripple, and "Fix sweep" word timing. See WaveformLineEditor.
    private func alignmentFixRow(index: Int) -> some View {
        let isRealigning = realigningCueIndex == index
        let anyRealigning = realigningCueIndex != nil
        let cue: SubtitleCue? = index < cues.count ? cues[index] : nil
        let isMusic = cue.map { SubtitleParser.isNonSpeechCue($0.text) } ?? true
        return VStack(spacing: 6) {
            // Target line + exactly what a commit does: its CURRENT start → the playhead it'll get.
            // The ▲▼ chevrons retarget without seeking (no hidden drag to discover).
            HStack(spacing: 8) {
                Button { adjustTargetIndex = max(0, (adjustTargetIndex ?? index) - 1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 26)
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(index <= 0)
                .accessibilityLabel("Target the previous line")

                HStack(spacing: 5) {
                    Text("Line \(cue?.index ?? index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(displayText(for: index))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { adjustTargetIndex = min(cues.count - 1, (adjustTargetIndex ?? index) + 1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 26)
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(index >= cues.count - 1)
                .accessibilityLabel("Target the next line")
            }

            // Waveform editor: drag green START / red END onto the audio; touch elsewhere to scrub.
            Group {
                if let waveform, let cue, isMusic == false {
                    let lineDur = max(0, cue.endMs - cue.startMs)
                    let pad = max(1500, lineDur)
                    WaveformLineEditor(
                        envelope: waveform,
                        windowStartMs: max(0, cue.startMs - pad),
                        windowEndMs: min(durationMs, cue.endMs + pad),
                        lineID: index,
                        lineStartMs: cue.startMs,
                        lineEndMs: cue.endMs,
                        playheadMs: controller.currentTimeMs,
                        onSetStart: { ms in onCueEdit(.setStartToMs(cueIndex: index, ms: ms)) },
                        onSetEnd: { ms in onCueEdit(.setEndToMs(cueIndex: index, ms: ms)) },
                        onSeek: { ms in controller.seek(toMs: ms) }
                    )
                    .frame(height: 66)
                } else if isMusic {
                    Text("♪ instrumental — no boundaries to drag")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 66)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading waveform…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                }
            }

            // Below: audition, ripple a drifted section, or re-run word timing.
            HStack(spacing: 8) {
                Button {
                    if controller.isPlaying { controller.pause() } else { controller.play() }
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 26)
                        .background(Color(.systemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                fixActionButton(title: "+ shift rest", system: "arrow.turn.down.right", tint: .systemBlue) {
                    onCueEdit(.setStartRipple(cueIndex: index))
                }
                .disabled(anyRealigning || isMusic)

                Spacer(minLength: 2)

                Button {
                    onCueEdit(.realignWord(cueIndex: index))
                } label: {
                    HStack(spacing: 3) {
                        if isRealigning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(isRealigning ? "Fixing…" : "Fix sweep")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color(.systemOrange))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color(.systemOrange).opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(anyRealigning || isMusic)
                .accessibilityLabel("Re-run word timing for this line")
            }
        }
        .opacity(anyRealigning ? 0.7 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.22))
        .task(id: "\(isAdjustingAlignment)|\(attachmentID?.uuidString ?? "")|\(isListeningToStem.wrappedValue)") {
            // Decode the waveform when Adjust opens or the Vocals/Mix toggle flips — isolated vocal
            // stem when "Vocals" is on and a stem is cached, otherwise the mix. Cached per (note,
            // source) so re-entering Adjust or toggling back doesn't redundantly re-decode.
            guard isAdjustingAlignment, let attachmentID,
                  let mixURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
            let useStem = isListeningToStem.wrappedValue && stemAvailable
            if waveform != nil, waveformNoteID == attachmentID, waveformIsStem == useStem { return }
            let src = useStem ? (VocalStemCache.stemWAVURL(for: mixURL) ?? mixURL) : mixURL
            let env = await WaveformEnvelope.load(url: src)
            if isAdjustingAlignment {
                waveform = env
                waveformNoteID = attachmentID
                waveformIsStem = useStem
            }
        }
    }

    // controls (bottom transport bar) and LyricsScrubber moved to LyricsView+Controls.swift
    // to keep this file under the repo's line-count cap.

}

