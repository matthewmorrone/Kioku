import SwiftUI
import UniformTypeIdentifiers

// Lifecycle and presentation composition for ReadView: layers the alert/sheet/dialog
// modifiers, the scenePhase + selection-change observers, and the NavigationStack-wrapped
// body that the top-level `body` ultimately renders.
extension ReadView {
    var alertingReadView: some View {
        lifecycleReadView
            .alert("Audio Transcription Failed", isPresented: audioTranscriptionErrorPresented) {
                Button("OK", role: .cancel) {
                    subtitleImport.audioTranscriptionErrorMessage = ""
                }
            } message: {
                Text(subtitleImport.audioTranscriptionErrorMessage)
            }
            .alert("Alignment Failed", isPresented: alignmentErrorPresented) {
                Button("OK", role: .cancel) {
                    lyricAlignment.errorMessage = ""
                }
            } message: {
                Text(lyricAlignment.errorMessage)
            }
            .alert("This Sounds Like Singing", isPresented: $subtitleImport.isShowingSungAudioRecommendation) {
                Button("Transcribe Anyway") { transcribePendingSungAudio() }
                Button("Cancel", role: .cancel) { discardPendingSungAudio() }
            } message: {
                Text("We recommend finding the song's lyrics online.")
            }
            .alert("AI Correction", isPresented: $llmCorrection.isShowingLLMCorrectionError) {
                Button("OK", role: .cancel) {
                    llmCorrection.llmCorrectionErrorMessage = ""
                }
            } message: {
                Text(llmCorrection.llmCorrectionErrorMessage)
            }
            .alert("Run AI Correction?", isPresented: $llmCorrection.isShowingLLMRunConfirm) {
                Button("Run") { requestLLMCorrection() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This sends the note to \(LLMSettings.remoteProvider().displayName), billed to your API key.")
            }
            .alert("Apply AI Changes?", isPresented: $llmCorrection.isShowingLLMConfirmAll) {
                Button("Apply All") { confirmLLMChanges() }
                Button("Reject All", role: .destructive) { rejectAllPendingLLMChanges() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(llmCorrection.pendingLLMChangedLocations.count) suggested change(s) are highlighted. Tap one to decide on it individually.")
            }
            .alert("Changes from Default", isPresented: $readSheets.isShowingChangesFromDefault) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(readSheets.changesFromDefault.isEmpty ? "None" : readSheets.changesFromDefault.joined(separator: "\n"))
            }
            .alert("AI Correction", isPresented: $llmCorrection.isShowingLLMChangePopover) {
                Button("Confirm") {
                    if let loc = llmCorrection.llmChangePopoverLocation {
                        confirmLLMChange(at: loc)
                    }
                }
                Button("Reject", role: .destructive) {
                    if let loc = llmCorrection.llmChangePopoverLocation {
                        rejectLLMChange(at: loc)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(llmCorrection.llmChangePopoverText)
            }
    }

    var lifecycleReadView: some View {
        selectionLifecycleReadView
            .onDisappear {
                // Flushes any pending edit persistence before leaving the read screen.
                document.segmentationRefreshTask?.cancel()
                document.segmentationRefreshTask = nil
                flushPendingNotePersistenceIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Flushes pending edits when the app moves to background so in-flight debounce tasks
                // are not lost when the process is killed (e.g. during a Xcode rebuild).
                if newPhase == .background {
                    flushPendingNotePersistenceIfNeeded()
                }
            }
    }

    var selectionLifecycleReadView: some View {
        presentedReadView
            .onAppear {
                // Syncs editor state when this screen first appears.
                loadSelectedNoteIfNeeded()
            }
            .onChange(of: selectedNote?.id) { _, _ in
                // Syncs editor state when Notes tab selects a different note.
                loadSelectedNoteIfNeeded()
            }
            .onChange(of: document.text) { oldText, newText in
                // Suppress this handler when the change was the load-handler's own assignment.
                // SwiftUI runs onChange after isLoadingSelectedNote has already been cleared, so
                // a flag isn't enough — match the actual value the loader wrote.
                if let snapshot = document.lastLoadedTextSnapshot, snapshot == newText {
                    document.lastLoadedTextSnapshot = nil
                    return
                }
                // Re-resolves cue highlight ranges only when the line count changes, since cue-to-line
                // mapping is stable for in-line edits but shifts whenever lines are added or removed.
                if audioPlayback.audioAttachmentCues.isEmpty == false {
                    let oldLineCount = oldText.components(separatedBy: .newlines).count
                    let newLineCount = newText.components(separatedBy: .newlines).count
                    if oldLineCount != newLineCount {
                        audioPlayback.audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(
                            for: audioPlayback.audioAttachmentCues,
                            in: newText
                        )
                    }
                }
                if editModeScroll.isEditMode {
                    // Preserve user customizations (splits/merges/furigana) in segments whose
                    // surfaces still match a prefix/suffix of the edited content. Only the
                    // diverging middle becomes an unsegmented stub; the segmenter will revisit
                    // it when edit mode exits.
                    let reconciled: [SegmentRange]?
                    if let existing = document.segments {
                        reconciled = reconcileSegments(existing, to: newText)
                    } else {
                        reconciled = nil
                    }
                    document.segments = reconciled
                    segmentSelection.illegalMergeBoundaryLocation = nil
                    segmentSelection.illegalMergeFlashTask?.cancel()
                    document.segmentationRefreshTask?.cancel()
                    document.segmentationRefreshTask = nil
                    document.furiganaComputationTask?.cancel()
                    document.furiganaComputationTask = nil
                    document.segmentLatticeEdges = []
                    document.segmentEdges = []
                    document.segmentRanges = []
                    segmentSelection.selectedSegmentLocation = nil
                    segmentSelection.selectedHighlightRangeOverride = nil
                    segmentSelection.selectedBounds = nil
                    SegmentLookupSheet.shared.dismissPopover()
                    // Rebuild the runtime furigana map from the reconciled segments so annotations
                    // in surviving regions are not dropped and their absolute offsets reflect any
                    // shift caused by length changes in the edited region.
                    if let reconciled {
                        let restored = furiganaFromSegmentRanges(reconciled)
                        document.furiganaBySegmentLocation = restored.byLocation
                        document.furiganaLengthBySegmentLocation = restored.lengthByLocation
                        document.chosenEntryIDBySegmentLocation = chosenEntryIDsFromSegmentRanges(reconciled)
                    } else {
                        document.furiganaBySegmentLocation = [:]
                        document.furiganaLengthBySegmentLocation = [:]
                        document.chosenEntryIDBySegmentLocation = [:]
                    }
                    scheduleCurrentNotePersistenceIfNeeded()
                    return
                }
                // Persists edits as content changes.
                scheduleCurrentNotePersistenceIfNeeded()
                // Recomputes segments only after full read resources are ready.
                if readResourcesReady {
                    refreshSegmentationRanges()
                }
            }
            .onChange(of: pendingScrollTarget) { _, _ in
                jumpToPendingScrollSurfaceIfReady()
            }
            .onChange(of: pendingAudioImportURL) { _, url in
                guard let url else { return }
                pendingAudioImportURL = nil
                Task { await prepareAudioImport(at: url) }
            }
            // Keeps the reset button's differsFromDefault current; a newer key cancels the older run.
            .task(id: defaultComparisonKey) {
                await refreshDiffersFromDefault()
            }
            .onChange(of: document.activeNoteID) { _, _ in
                // activeNoteID and text update together (loadSelectedNoteIfNeeded), but that load
                // can finish either before or after pendingScrollTarget arrives from ContentView —
                // whichever onChange fires last is the one that actually has both pieces ready.
                jumpToPendingScrollSurfaceIfReady()
                startPendingAutoplayIfReady()
            }
            .onChange(of: pendingAutoplayNoteID) { _, _ in
                startPendingAutoplayIfReady()
            }
            .onChange(of: editModeScroll.isEditMode) { _, editing in
                if editing {
                    // Hand the CT read view's live scroll position to the editor. The CT
                    // renderer reports into the reference-type memo (not @State) while the
                    // user scrolls in view mode; this is the one moment the shared offset
                    // needs to catch up so RichTextEditor's applyExternalScrollIfNeeded
                    // restores the same position. Without this, the editor opened at a stale
                    // offset (last edit position or last sheet adjustment).
                    editModeScroll.sharedScrollOffsetY = editModeScroll.readScrollOffsetMemo.value
                    // Suspends in-progress furigana / segmentation work and clears transient
                    // selection state. Note: we deliberately do NOT clear furiganaBySegmentLocation
                    // here. The renderer is gated by `isActive: editModeScroll.isEditMode == false`, so it
                    // doesn't read the map during editing, and keeping the user's chosen
                    // readings in memory means we never have to "restore" them on exit.
                    // onChange(of: text) handles real text edits via reconcileSegments.
                    segmentSelection.illegalMergeBoundaryLocation = nil
                    segmentSelection.illegalMergeFlashTask?.cancel()
                    document.segmentationRefreshTask?.cancel()
                    document.segmentationRefreshTask = nil
                    document.furiganaComputationTask?.cancel()
                    document.furiganaComputationTask = nil
                    document.segmentLatticeEdges = []
                    document.segmentEdges = []
                    document.segmentRanges = []
                    segmentSelection.selectedSegmentLocation = nil
                    segmentSelection.selectedHighlightRangeOverride = nil
                    segmentSelection.selectedBounds = nil
                    SegmentLookupSheet.shared.dismissPopover()
                } else {
                    // Always flush pending edits when leaving edit mode so no changes are lost.
                    flushPendingNotePersistenceIfNeeded()
                    // Recomputes once when returning to view mode so furigana matches latest text.
                    if readResourcesReady {
                        refreshSegmentationRanges()
                    }
                }
            }
            .onChange(of: audioPlayback.isShowingLyricsView) { _, isShowing in
                if isShowing { autoAlignIfNeeded() }
            }
            .onChange(of: segmenterRevision) { _, _ in
                if document.text.isEmpty == false, debugStartupSegmentationDiffs {
                    StartupTimer.measure("SegmentationDiffPrinter.printDiffs") {
                        SegmentationDiffPrinter.printDiffs(for: document.text, trieSegmenter: segmenter)
                    }
                }

                // When segments are persisted, schedule furigana generation unconditionally
                // so the now-loaded surfaceReadingData has a chance to upgrade per-character
                // fragments to the compound reading (e.g. もの+ご at 物+語 → ものがたり covering
                // both kanji). The previous "skip when already populated" guard let stale
                // per-character entries from disk persist forever once resources loaded
                // post-note-open. The recompute uses replace-on-overlap semantics — exact-
                // range entries survive (user pins, prior-correct annotations) while
                // fragmented narrow entries get superseded by wider compound spans.
                // Otherwise (no persisted segments) recompute full segmentation.
                if document.segments != nil {
                    StartupTimer.mark("scheduling furigana now that surfaceReadingData is ready")
                    scheduleFuriganaGeneration(for: document.text, edges: document.segmentEdges)
                } else {
                    StartupTimer.mark("no persisted segments, running full segmentation")
                    refreshSegmentationRanges()
                }

                // Lyrics opened on an unaligned song before the dictionary loaded can align now.
                autoAlignIfNeeded()

                // Resources just became ready. A split editor opened while they were still loading has
                // no costs; re-install the provider with the now-loaded segmenter so it fills in.
                SegmentLookupSheet.shared.refreshOpenSheetSplitCostsProvider { candidates in
                    splitCostsForCurrentSelectedSegment(candidates)
                }

                // Replays a tap that arrived before resources were ready (see
                // handleReadModeSegmentTap's readResourcesReady guard) — a conjugated word tapped
                // in the first moment after launch otherwise looked like it silently did nothing.
                // Goes straight to the lookup half (selectedSegmentLocation is already set from
                // the original tap) rather than re-entering handleReadModeSegmentTap, which would
                // see it as already-selected and toggle it off instead of looking it up.
                if let pending = segmentSelection.pendingSegmentTapAfterResourcesReady, let location = pending.location {
                    segmentSelection.pendingSegmentTapAfterResourcesReady = nil
                    presentLookupForSegmentTap(
                        tappedSegmentLocation: location,
                        tappedSegmentRect: pending.rect,
                        sourceView: pending.sourceView
                    )
                }
            }
    }

    var presentedReadView: some View {
        NavigationStack {
            titleView
            VStack(spacing: 10) {
                editorView
                toolbarButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .toolbar(.visible, for: .tabBar)
        .background {
            AudioCueHighlightObserver(
                controller: audioPlayback.audioController,
                cues: audioPlayback.audioAttachmentCues,
                highlightRanges: audioPlayback.audioAttachmentHighlightRanges,
                granularity: lyricsHighlightGranularity,
                segmentationRanges: document.segmentRanges,
                noteText: document.text,
                playbackHighlightRangeOverride: $audioPlayback.playbackHighlightRangeOverride,
                activePlaybackCueIndex: $audioPlayback.activePlaybackCueIndex
            )
        }
        .overlay(alignment: .topLeading) {
            // Pixel ruler is non-interactive and only drawn when its debug toggle is active.
            if debugPixelRuler {
                PixelRulerOverlayView()
            }
        }
        .overlay {
            if audioPlayback.activeAudioAttachmentID != nil {
                LyricsView(
                    controller: audioPlayback.audioController,
                    cues: audioPlayback.audioAttachmentCues,
                    highlightRanges: audioPlayback.audioAttachmentHighlightRanges,
                    furiganaBySegmentLocation: document.furiganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: document.furiganaLengthBySegmentLocation,
                    segmentationRanges: document.segmentRanges,
                    noteText: document.text,
                    attachmentID: audioPlayback.activeAudioAttachmentID,
                    noteID: document.activeNoteID,
                    playbackHighlightRangeOverride: lyricsHighlightGranularity == .sentence
                        ? nil
                        : audioPlayback.playbackHighlightRangeOverride,
                    granularity: lyricsHighlightGranularity,
                    isSavedHighlightEnabled: isSavedHighlightEnabled,
                    savedSegmentLocations: savedSegmentLocations,
                    savedLearnedSegmentLocations: savedLearnedSegmentLocations,
                    savedNotLearnedSegmentLocations: savedNotLearnedSegmentLocations,
                    onSegmentTapped: { location, rect, sourceView in
                        handleReadModeSegmentTap(location, tappedSegmentRect: rect, sourceView: sourceView)
                    },
                    onDismiss: {
                        audioPlayback.isShowingLyricsView = false
                    },
                    onReAlign: { Task { await realignWholeNote() } },
                    onReplaceAudio: { subtitleImport.isShowingLyricMediaPicker = true },
                    onRemoveAudio: { resetCurrentSubtitleAttachment() },
                    isReAligning: lyricAlignment.isAligning,
                    reAlignMessage: lyricAlignment.progressMessage,
                    onCancelReAlign: { cancelAlignment() },
                    isCancellingReAlign: subtitleImport.isCancellingAlignment,
                    audioSource: audioPlayback.audioSource,
                    isSwitchingAudioSource: audioPlayback.isSwitchingAudioSource,
                    onCycleAudioSource: { cycleLyricAudioSource() }
                )
                .opacity(audioPlayback.isShowingLyricsView ? 1 : 0)
                .allowsHitTesting(audioPlayback.isShowingLyricsView)
                .animation(.easeInOut(duration: 0.2), value: audioPlayback.isShowingLyricsView)
            }
        }
        .sheet(isPresented: $readSheets.isShowingSegmentList) {
            SegmentListView(
                text: document.text,
                edges: document.segmentEdges,
                latticeEdges: document.segmentLatticeEdges,
                dictionaryStore: dictionaryStore,
                segmenter: segmenter,
                lexicon: lexicon,
                sourceNoteID: document.activeNoteID,
                note: currentDisplayedNote,
                lemmaForSurface: { segmenter.preferredLemma(for: $0) },
                lemmaCandidatesForSurface: { segmenter.lemmaCandidates(for: $0) },
                onMergeLeft: { edgeIndex in
                    mergeSegmentFromSegmentList(at: edgeIndex, isMergingLeft: true)
                },
                onMergeRight: { edgeIndex in
                    mergeSegmentFromSegmentList(at: edgeIndex, isMergingLeft: false)
                },
                onSplit: { edgeIndex, splitOffset in
                    splitSegmentFromSegmentList(at: edgeIndex, offsetUTF16: splitOffset)
                },
                onReset: {
                    resetSegmentationToComputed()
                }
            )
        }
        // Lyric-button quick-load picker: one shot for audio + subtitle/textgrid. Multi-select so
        // the user can grab "song.mp3" and "song.srt" (or "song.TextGrid") together; the handler
        // sorts them by kind and imports in one pass.
        .fileImporter(
            isPresented: $subtitleImport.isShowingLyricMediaPicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .subripText, .praatTextGrid],
            allowsMultipleSelection: true
        ) { result in
            handleLyricMediaSelection(result)
        }
        // Sheet entry point for the LLM breakdown — moved off the Learn tab. SongStepperView
        // expects to live in a NavigationStack for its principal/trailing toolbar items, so
        // we wrap it here at presentation time rather than at the call site.
        //
        // We resolve the displayed note via `activeNoteID + notesStore` rather than via the
        // `selectedNote` binding: ReadView's load handler consumes `selectedNote` (sets it
        // to nil) once the note has been loaded into `text` / `activeNoteID`, so reading
        // the binding here would always see nil and render an empty sheet.
        .sheet(isPresented: $readSheets.isShowingLearnSpelling) {
            CustomWordEditorView(
                existing: nil,
                spelling: readSheets.learnSpellingSurface,
                dictionaryStore: dictionaryStore,
                onFinish: { readSheets.isShowingLearnSpelling = false }
            )
        }
        .sheet(isPresented: $readSheets.isShowingTextConversion) {
            TextConversionSheet(
                proposals: $readSheets.textConversionProposals,
                onApply: { applyTextConversion() },
                onCancel: { readSheets.isShowingTextConversion = false }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $readSheets.isShowingBreakdownSheet) {
            if let note = currentDisplayedNote {
                NavigationStack {
                    // Threading the segmenter + surfaceReadingData lets the breakdown's
                    // per-line tap-to-toggle furigana reuse the same FuriganaResolver as
                    // ReadView itself, so the readings shown in the sheet match exactly
                    // what the user sees on the underlying page.
                    SongStepperView(
                        note: note,
                        segmenter: segmenter,
                        surfaceReadingData: surfaceReadingData,
                        kanjiReadingFallback: kanjiReadingFallback,
                        dictionaryStore: dictionaryStore,
                        segmenterRevision: segmenterRevision
                    )
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { readSheets.isShowingBreakdownSheet = false }
                            }
                        }
                }
            }
        }
    }

    // Starts the "Sing with Kioku" note from the top with the lyrics view open, once that note is the
    // one loaded (its audio attachment is loaded in the same pass as activeNoteID). Waits on
    // activeNoteID for the same ordering reason as jumpToPendingScrollSurfaceIfReady.
    func startPendingAutoplayIfReady() {
        guard let noteID = pendingAutoplayNoteID, document.activeNoteID == noteID else { return }
        pendingAutoplayNoteID = nil
        guard audioPlayback.activeAudioAttachmentID != nil else { return }
        audioPlayback.isShowingLyricsView = true
        audioPlayback.audioController.playFromStart()
    }

    // Consumes pendingScrollTarget once the note it names is actually the one loaded into `text`
    // — guards on activeNoteID rather than acting the instant the target arrives, since ContentView
    // sets selectedReadNote and pendingScrollTarget together but loadSelectedNoteIfNeeded's text/
    // activeNoteID update can land on either side of that in the update cycle. Finds the surface's
    // first occurrence, selects it (the same highlight the lookup sheet's star context menu shows)
    // and borrows audioPlayback.playbackHighlightRangeOverride to scroll it into view — the one existing
    // scroll-to-range mechanism in this renderer, normally driven by audio cue playback (see
    // KiokuCoreTextRendererView's scrollRangeIntoView call). Safe to reuse outside playback: the
    // "unplayed" dimming it also drives requires real cue data (cueHasReliableDimCoverage), which
    // isn't present here, so only the scroll + a plain highlight tint apply.
    func jumpToPendingScrollSurfaceIfReady() {
        guard let target = pendingScrollTarget, document.activeNoteID == target.noteID else { return }
        guard let range = document.text.range(of: target.surface) else {
            pendingScrollTarget = nil
            return
        }
        let nsRange = NSRange(range, in: document.text)
        guard nsRange.length > 0 else {
            pendingScrollTarget = nil
            return
        }
        segmentSelection.selectedSegmentLocation = nsRange.location
        segmentSelection.selectedHighlightRangeOverride = nsRange
        audioPlayback.playbackHighlightRangeOverride = nsRange
        pendingScrollTarget = nil

        audioPlayback.pendingScrollHighlightClearTask?.cancel()
        audioPlayback.pendingScrollHighlightClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            if audioPlayback.playbackHighlightRangeOverride == nsRange {
                audioPlayback.playbackHighlightRangeOverride = nil
            }
        }
    }
}
