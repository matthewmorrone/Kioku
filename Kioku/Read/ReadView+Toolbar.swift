import SwiftUI

// Single source of truth for the Read tab's toggle appearance, modeled on the
// furigana button: a constant neutral background, with the foreground switching
// between accent (on) and secondary (off). Every toggle on the Read tab — the
// icon buttons in the toolbar / title rows, the display-options popover rows,
// and the pill filters in the segment list and lyrics views — routes its colors
// through here so the whole tab speaks one visual language. The background never
// changes with state; only the foreground signals on/off.
enum ReadToggleAppearance {
    static let background = Color(.tertiarySystemFill)

    // Accent when the toggle is on, secondary when off — the only thing that
    // changes with state, since the background stays constant.
    static func foreground(isOn: Bool) -> Color {
        isOn ? Color.accentColor : Color.secondary
    }
}

// Toolbar buttons and display options popover for ReadView.
extension ReadView {
    // Renders action buttons for segmentation and display controls. The lyrics (♪) and
    // LLM correction (sparkles) buttons that used to live here moved up to the title
    // row; extract-words (list.bullet) moved the other way, down from the title row,
    // so this row now hosts extract-words / reset / edit.
    var toolbarButtons: some View {
        HStack {
            Spacer()
            titleExtractWordsButton
                .tourTarget(.readExtractWords)
            resetButton
                .tourTarget(.readReset)
            editModeButton
                .tourTarget(.readEdit)
        }
    }

    // The AI correction button. Idle: requests a correction for this note. While one streams:
    // a spinner, and tapping cancels. While suggestions are pending: sparkles + checkmark, which
    // opens the "apply all?" popup — nothing is applied without a decision there or in a single
    // change's popup. Disabled (not hidden) with no provider configured, so its absence doesn't
    // read as "this feature doesn't exist".
    var llmCorrectionButton: some View {
        Button {
            if llmCorrection.isRequestingLLMCorrection {
                cancelLLMCorrection()
            } else if llmCorrection.hasPendingLLMChanges {
                llmCorrection.isShowingLLMConfirmAll = true
            } else if LLMSettings.isPaid() {
                llmCorrection.isShowingLLMRunConfirm = true
            } else {
                requestLLMCorrection()
            }
        } label: {
            Group {
                if llmCorrection.isRequestingLLMCorrection {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                } else if llmCorrection.hasPendingLLMChanges {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "sparkles")
                            .scaledFont(size: 16, weight: .semibold)
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 10, weight: .bold)
                            .offset(x: 4, y: 4)
                    }
                } else {
                    Image(systemName: "sparkles")
                        .scaledFont(size: 16, weight: .semibold)
                }
            }
            .foregroundStyle(llmCorrection.hasPendingLLMChanges ? Color.green : Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Circle().fill(ReadToggleAppearance.background))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(editModeScroll.isEditMode || isCorrectionConfigured == false)
        .opacity(editModeScroll.isEditMode || isCorrectionConfigured == false ? 0.5 : 1.0)
        .accessibilityLabel(llmCorrection.hasPendingLLMChanges ? "Review AI Changes" : (llmCorrection.isRequestingLLMCorrection ? "Cancel AI Correction" : "Request AI Correction"))
        .accessibilityHint(isCorrectionConfigured ? "" : "Set up an AI provider in Settings to use this")
    }

    // Opens Changes from Default, which lists how the note differs from Kioku's own segmentation
    // and readings and holds the Reset that restores them. While LLM changes are pending, shows a
    // red X badge and rejects all AI changes instead.
    var resetButton: some View {
        // Enabled only when the user has actually changed this note's segmentation or readings, the
        // note no longer matches what the segmenter produces (differsFromDefault — a segmenter
        // change with no edit to the note), or there are pending AI changes to reject; and the note
        // isn't in edit mode. Uses the
        // explicit edit marker rather than `segments != nil`, which is true even for imported /
        // precomputed notes that were never touched. Per the toggle standard, an enabled reset
        // reads as "on" (accent) and a disabled one as "off" (secondary); the red reject badge
        // overrides while AI changes are pending.
        let isEnabled = (document.hasManualSegmentationEdits || document.differsFromDefault || llmCorrection.hasPendingLLMChanges)
            && editModeScroll.isEditMode == false
        // Segmentation or its furigana pass is still running: the icon becomes a spinner.
        let isSegmenting = document.segmentationRefreshTask != nil || document.furiganaComputationTask != nil
        return Button {
            if llmCorrection.hasPendingLLMChanges {
                // Nothing has been written to the document yet — just drop the proposal,
                // without touching any manual segmentation edits made before it.
                rejectAllPendingLLMChanges()
            } else {
                showChangesFromDefault()
            }
        } label: {
            Group {
                if llmCorrection.hasPendingLLMChanges {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.counterclockwise")
                            .scaledFont(size: 16, weight: .semibold)
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 10, weight: .bold)
                            .offset(x: 4, y: 4)
                    }
                    .foregroundStyle(Color.red)
                } else if isSegmenting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEnabled))
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(ReadToggleAppearance.background))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled || isSegmenting ? 1.0 : 0.5)
        .accessibilityLabel(llmCorrection.hasPendingLLMChanges ? "Reject AI Changes" : "Changes from Default")
    }

    // Title-row buttons. New-note + OCR migrated to the Notes tab; this row hosts the
    // per-note quick actions: open the lyrics view (♪), open the segment list / extract-words
    // (list.bullet), and open the LLM breakdown sheet (sparkles in a circle). All three are
    // visual peers — same capsule background, same accent treatment — so the row reads as
    // "actions for the currently-open note."
    // Accent (blue) once the note has an alignment — any timed lyric line, not just ♪ markers —
    // or while the lyrics view is open; secondary otherwise.
    // While the song aligns, a spinner stands in for the ♪.
    var titleLyricsButton: some View {
        let isAligned = audioPlayback.audioAttachmentCues.contains { SubtitleParser.isNonSpeechCue($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) == false }
        return Group {
            if lyricAlignment.isAligning {
                titleActionLabel {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                titleActionLabel(systemImage: "music.note", foreground: ReadToggleAppearance.foreground(isOn: isAligned || audioPlayback.isShowingLyricsView))
            }
        }
            .contentShape(Capsule())
            .onTapGesture {
                // A first import's attachment doesn't exist until its alignment finishes, so the
                // spinner ignores taps then rather than reopening the media picker underneath it.
                // A note that already has audio still toggles: the lyric view shows the
                // alignment's progress and its Cancel button.
                guard lyricAlignment.isAligning == false || audioPlayback.activeAudioAttachmentID != nil else { return }
                // Nothing attached yet → the lyric view would be empty, so jump straight to the
                // media picker (mp3 / srt / textgrid) instead of toggling a blank overlay. Once an
                // attachment exists, the tap reverts to its normal show/hide-lyrics behavior; opening
                // the lyrics on a note with no cues yet starts alignment (autoAlignIfNeeded).
                if audioPlayback.activeAudioAttachmentID == nil {
                    subtitleImport.isShowingLyricMediaPicker = true
                } else {
                    audioPlayback.isShowingLyricsView.toggle()
                    // How long the main thread stays busy after the tap, i.e. how late the view shows.
                    StartupTimer.mark("lyrics toggle tapped (showing=\(audioPlayback.isShowingLyricsView))")
                    DispatchQueue.main.async { StartupTimer.mark("lyrics toggle: main thread free") }
                }
            }
            .accessibilityLabel(lyricAlignment.isAligning ? "Aligning Lyrics" : (audioPlayback.isShowingLyricsView ? "Hide Lyrics" : "Show Lyrics"))
            .accessibilityAddTraits(.isButton)
    }

    // Tap opens the segment list; long-press lists the note's changes from default segmentation
    // and readings.
    var titleExtractWordsButton: some View {
        titleActionLabel(systemImage: "list.bullet", foreground: .accentColor)
            .contentShape(Capsule())
            .onTapGesture {
                readSheets.isShowingSegmentList = true
            }
            .accessibilityLabel("Extract Words")
            .accessibilityAddTraits(.isButton)
    }

    // Shows how the note's current segmentation and readings differ from the default.
    func showChangesFromDefault() {
        Task {
            guard let lines = await changesFromDefault() else { return }
            readSheets.changesFromDefault = lines
            readSheets.isShowingChangesFromDefault = true
        }
    }

    // Runs the segmenter and reading resolver fresh for the note, off the main thread, and lists how
    // the note's current segmentation and readings differ from that default. Nil when the text
    // changed while it ran. The one comparison behind both "Changes from Default" and
    // differsFromDefault, so the reset button and the list agree.
    func changesFromDefault() async -> [String]? {
        // Before the dictionary lands, the "default" would be one-character pieces with no readings.
        await segmenter.waitUntilLoaded()
        let text = document.text
        let currentEdges = document.segmentEdges
        let currentFurigana = (
            byLocation: document.furiganaBySegmentLocation,
            lengthByLocation: document.furiganaLengthBySegmentLocation
        )
        let resolver = FuriganaResolver(segmenter: segmenter, kanjiReadingFallback: kanjiReadingFallback)
        let readingData = surfaceReadingData
        let lines = await Task.detached(priority: .utility) { [segmenter] in
            let defaultEdges = segmenter.longestMatchResult(for: text).selectedEdges
            let defaultFurigana = resolver.build(for: text, edges: currentEdges, surfaceReadingData: readingData)
            return SegmentationChangeList.lines(
                text: text,
                defaultEdges: defaultEdges,
                currentEdges: currentEdges,
                defaultFurigana: defaultFurigana,
                currentFurigana: currentFurigana
            )
        }.value
        guard document.text == text else { return nil }
        return lines
    }

    // What the default comparison depends on; differsFromDefault is recomputed when it changes.
    var defaultComparisonKey: DefaultComparisonKey {
        DefaultComparisonKey(
            text: document.text,
            segmentRanges: document.segmentRanges,
            furigana: document.furiganaBySegmentLocation,
            segmenterRevision: segmenterRevision,
            resourcesReady: readResourcesReady,
            isEditing: editModeScroll.isEditMode
        )
    }

    // Recomputes differsFromDefault for the note on screen. Skipped until the segmenter is loaded
    // and while the note is being edited, when the comparison would be against a moving target.
    func refreshDiffersFromDefault() async {
        guard readResourcesReady, editModeScroll.isEditMode == false, document.text.isEmpty == false else {
            document.differsFromDefault = false
            return
        }
        guard let lines = await changesFromDefault(), Task.isCancelled == false else { return }
        document.differsFromDefault = lines.isEmpty == false
    }

    // True while a breakdown generation is in flight for the currently-open note — surfaced
    // as a spinner on the toolbar icon so a multi-minute LLM call (often 60-180s) doesn't read
    // as an inert button while it's actually working in the background.
    private var isBreakdownGeneratingForActiveNote: Bool {
        guard let activeNoteID = document.activeNoteID else { return false }
        return songBreakdownStore.isGenerating(forNoteID: activeNoteID)
    }

    var titleBreakdownButton: some View {
        Button {
            readSheets.isShowingBreakdownSheet = true
        } label: {
            if isBreakdownGeneratingForActiveNote {
                titleActionLabel {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                // Accent (blue) once the note has a breakdown, secondary before — as the ♪ button does
                // for an alignment.
                let hasBreakdown = document.activeNoteID.map { songBreakdownStore.hasBreakdown(forNoteID: $0) } ?? false
                titleActionLabel(systemImage: "sparkles.rectangle.stack", foreground: ReadToggleAppearance.foreground(isOn: hasBreakdown))
            }
        }
        .buttonStyle(.plain)
        .disabled(isBreakdownConfigured == false)
        .opacity(isBreakdownConfigured ? 1.0 : 0.5)
        .accessibilityLabel(isBreakdownGeneratingForActiveNote ? "Breakdown generating" : "Open Breakdown")
        .accessibilityHint(isBreakdownConfigured ? "" : "Set up an AI provider in Settings to use this")
    }

    // Shared visual treatment for the three title-row action buttons. Sized to match the bottom
    // toolbar's furigana / reset / edit buttons (36×36 with a 16pt icon) so the two rows read as
    // visual peers — same hit area, same inter-button gap when each row is laid out with default
    // `HStack` spacing. A smaller visible pill inside a larger hit frame would make HStack measure
    // invisible padding per button and space this row wider than the bottom one. Not private:
    // reused by ReadView+MiniPlayer.swift's inline play/pause button so it matches the other
    // title-row icons exactly.
    func titleActionLabel(systemImage: String, foreground: Color) -> some View {
        titleActionLabel {
            Image(systemName: systemImage)
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(foreground)
        }
    }

    // Same frame/background/hit-area as above, around arbitrary content — lets a busy state
    // (e.g. titleLyricsButton's spinner while a song aligns) share the box without duplicating it.
    func titleActionLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 36, height: 36)
            .background(Capsule().fill(ReadToggleAppearance.background))
            .contentShape(Rectangle())
    }

    // Presents display option toggles with persistent enabled-state styling.
    var displayOptionsPopover: some View {
        VStack(spacing: 10) {
            displayOptionRow(
                title: "Apply Changes Globally",
                systemImage: "arrow.triangle.branch",
                isEnabled: shouldApplyChangesGlobally,
                info: "When you merge or split a word, make the same change everywhere that word appears in the note."
            ) {
                shouldApplyChangesGlobally.toggle()
            }

            displayOptionRow(
                title: "Furigana",
                image: Image(isFuriganaVisible ? "furigana.on" : "furigana.off")
                    .renderingMode(.template),
                isEnabled: isFuriganaVisible,
                info: "Show readings above words with kanji."
            ) {
                isFuriganaVisible.toggle()
            }

            displayOptionRow(
                title: "Hide Known Furigana",
                systemImage: isFuriganaHiddenForKnownWords ? "eye.slash.circle.fill" : "eye.slash.circle",
                isEnabled: isFuriganaHiddenForKnownWords,
                info: "Drop the furigana from words you've marked learned or mastered."
            ) {
                isFuriganaHiddenForKnownWords.toggle()
            }

            // The indicator mirrors the stored flag directly: `isLineWrappingEnabled == true`
            // maps to `.byWordWrapping` in every render site, so a checkmark/highlight means
            // "lines are wrapping." No inversion — display and behavior track the same flag.
            displayOptionRow(
                title: "Line Wrapping",
                systemImage: isLineWrappingEnabled ? "text.alignleft" : "arrow.right.to.line.compact",
                isEnabled: isLineWrappingEnabled,
                info: "Wrap long lines to fit the screen. Off, each line of the note stays on one line."
            ) {
                isLineWrappingEnabled.toggle()
            }

            displayOptionRow(
                title: "Ruby Spacing",
                systemImage: isRubySpacingEnabled ? "arrow.left.and.right.text.vertical" : "arrow.left.and.right",
                isEnabled: isRubySpacingEnabled,
                info: "Space words out so each word's furigana fits above it without running into its neighbors."
            ) {
                isRubySpacingEnabled.toggle()
            }

            displayOptionRow(
                title: "Segment Colors",
                systemImage: isColorAlternationEnabled ? "paintpalette.fill" : "paintpalette",
                isEnabled: isColorAlternationEnabled,
                info: "Alternate the text color from word to word, to show where Kioku split the text."
            ) {
                isColorAlternationEnabled.toggle()
            }

            savedHighlightRow

            // Dimmed when the note has nothing to clean up.
            displayOptionRow(
                title: "Cleanup",
                systemImage: "character.book.closed.ja",
                isEnabled: false,
                isActionDisabled: noteNeedsCleanup == false,
                info: "Suggest fixes for the note's text: English words turned into katakana, and half-width kana or full-width digits normalized. You review each change first."
            ) {
                startCleanup()
            }
        }
        .padding(12)
        .frame(width: 270)
    }

    // "Saved Highlight" row: tapping the row toggles the highlight on/off AND bulk-sets all
    // three submenu categories to match, so turning it off from here hides everything and
    // turning it on shows everything — a shortcut for the common case. The chevron submenu still
    // holds three INDEPENDENT toggles, one per Learned-state category, for narrowing after that;
    // each is its own on/off, not a single-select mode, so any combination can be showing at
    // once. Each category always renders in its own fixed color (Save/Learned/Not Learned)
    // when its toggle is on — see ReadView+Editor.computeSavedSegmentLocations.
    private var savedHighlightRow: some View {
        HStack(spacing: 4) {
            Button {
                isSavedHighlightEnabled.toggle()
                isSavedHighlightShowingSaved = isSavedHighlightEnabled
                isSavedHighlightShowingLearned = isSavedHighlightEnabled
                isSavedHighlightShowingNotLearned = isSavedHighlightEnabled
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSavedHighlightEnabled ? "star.fill" : "star")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(ReadToggleAppearance.foreground(isOn: isSavedHighlightEnabled))
                        .frame(width: 20)
                    Text("Saved Highlight")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(ReadToggleAppearance.foreground(isOn: isSavedHighlightEnabled))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .allowsTightening(true)
                    Spacer(minLength: 0)
                    if isSavedHighlightEnabled {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            InfoButton(text: "Color the words you've saved. The chevron picks which kinds: saved, learned or not learned.")

            Button {
                readSheets.isShowingSavedHighlightCategories = true
            } label: {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .popover(isPresented: $readSheets.isShowingSavedHighlightCategories, arrowEdge: .trailing) {
                savedHighlightCategoriesPopover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ReadToggleAppearance.background)
        )
    }

    // Real Toggle rows (not Menu items) so flipping several in a row doesn't dismiss the
    // popover between taps — see isShowingSavedHighlightCategories's doc comment. Highlight
    // Unknown lives here too, separated by a divider: it isn't one of the Saved-word categories
    // the "Saved Highlight" row's master toggle bulk-sets, but it's the same kind of control —
    // an independent per-category highlight toggle — so it belongs in this popover rather than
    // as its own top-level row.
    private var savedHighlightCategoriesPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Save", isOn: $isSavedHighlightShowingSaved)
            Toggle("Learned", isOn: $isSavedHighlightShowingLearned)
            Toggle("Not Learned", isOn: $isSavedHighlightShowingNotLearned)
            Divider()
            Toggle(isOn: $isHighlightUnknownEnabled) {
                Text("Highlight Unknown")
                    .infoButton("Color words the dictionary doesn't recognize.")
            }
        }
        .padding(16)
        .frame(width: 200)
        .presentationCompactAdaptation(.popover)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Renders one display-option row with a highlighted background while its toggle is enabled.
    func displayOptionRow(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        isActionDisabled: Bool = false,
        info: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        displayOptionRow(
            title: title,
            image: Image(systemName: systemImage),
            isEnabled: isEnabled,
            isActionDisabled: isActionDisabled,
            info: info,
            action: action
        )
    }

    // Image-based overload of displayOptionRow for rows whose icon is a custom Image
    // asset rather than an SF Symbol — e.g. the furigana glyph, which is a project
    // asset, not a system symbol. Shares all other styling with the systemImage variant
    // so the popover keeps a single visual language.
    // `info`, when given, adds an ⓘ popover beside the row's button (not inside it, so it takes
    // its own tap), within the same rounded background. `isActionDisabled` dims and disables only
    // the button, so the ⓘ still explains a row that can't be used right now.
    func displayOptionRow(
        title: String,
        image: Image,
        isEnabled: Bool,
        isActionDisabled: Bool = false,
        info: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 10) {
                    image
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEnabled))
                        .frame(width: 20)
    
                    Text(title)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEnabled))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .allowsTightening(true)
    
                    Spacer(minLength: 0)
    
                    if isEnabled {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isActionDisabled)
            .opacity(isActionDisabled ? 0.4 : 1)
            if let info {
                InfoButton(text: info)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(ReadToggleAppearance.background)
        )
    }

    // One icon button whose visual treatment reflects active edit state. Tap toggles
    // edit mode; long press opens the display-options popover (which now hosts furigana
    // alongside the other view-mode toggles). Locked while an LLM correction is in flight:
    // entering edit mode mid-call would let the user mutate `text` out from under the
    // apply pipeline, which validates the response against the text that was originally
    // submitted. Cheaper than threading a background task across view transitions — the
    // call only survives a couple of minutes, and the user can still navigate elsewhere;
    // they just can't edit until the correction lands. The popover stays available even
    // while the button is disabled would feel wrong, so the long-press is gated on the
    // same condition as the tap.
    var editModeButton: some View {
        editModeButtonLabel
            .contentShape(Circle())
            .onTapGesture {
                // Editing mid-correction would invalidate the text the answer is being staged against.
                guard llmCorrection.isRequestingLLMCorrection == false else { return }
                editModeScroll.isEditMode.toggle()
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                guard llmCorrection.isRequestingLLMCorrection == false else { return }
                readSheets.isShowingDisplayOptions = true
            }
            .disabled(llmCorrection.isRequestingLLMCorrection)
            .opacity(llmCorrection.isRequestingLLMCorrection ? 0.4 : (editModeScroll.isEditMode ? 1 : 0.7))
            .accessibilityLabel(editModeScroll.isEditMode ? "Disable Edit Mode" : "Enable Edit Mode")
            .accessibilityHint(llmCorrection.isRequestingLLMCorrection ? "Disabled while AI correction runs" : "Long press for display options")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $readSheets.isShowingDisplayOptions, arrowEdge: .bottom) {
                displayOptionsPopover
                    .presentationCompactAdaptation(.popover)
                    .fixedSize(horizontal: false, vertical: true)
                    .presentationBackground(Color(.systemBackground))
            }
    }

    // Renders the edit-mode glyph so the gesture-driven editModeButton has a label view
    // to attach taps and long-presses to without nesting them inside a Button.
    private var editModeButtonLabel: some View {
        Image(systemName: "character.cursor.ibeam.ja")
            .scaledFont(size: 16, weight: .semibold)
            .foregroundStyle(ReadToggleAppearance.foreground(isOn: editModeScroll.isEditMode))
            .frame(width: 36, height: 36)
            .background(Circle().fill(ReadToggleAppearance.background))
    }
}
