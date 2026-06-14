import SwiftUI
import UniformTypeIdentifiers

// Lifecycle and presentation composition for ReadView: layers the alert/sheet/dialog
// modifiers, the scenePhase + selection-change observers, and the NavigationStack-wrapped
// body that the top-level `body` ultimately renders.
extension ReadView {
    var alertingReadView: some View {
        lifecycleReadView
            .sheet(isPresented: $isShowingSubtitleEditor) {
                if let attachmentID = activeAudioAttachmentID {
                    SubtitleEditorSheet(
                        attachmentID: attachmentID,
                        initialCues: audioAttachmentCues,
                        noteText: text
                    ) { newCues in
                        // Reload the controller with updated cues so highlighting stays in sync.
                        audioAttachmentCues = newCues
                        if let url = NotesAudioStore.shared.audioURL(for: attachmentID) {
                            do {
                                try audioController.load(audioURL: url, cues: newCues)
                            } catch {
                                print("[ReadView] reload after subtitle edit failed for \(url.lastPathComponent): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
            .alert("Audio Transcription Failed", isPresented: audioTranscriptionErrorPresented) {
                Button("OK", role: .cancel) {
                    audioTranscriptionErrorMessage = ""
                }
            } message: {
                Text(audioTranscriptionErrorMessage)
            }
            .alert("Generate SRT Failed", isPresented: lyricAlignmentErrorPresented) {
                Button("OK", role: .cancel) {
                    lyricAlignmentErrorMessage = ""
                }
            } message: {
                Text(lyricAlignmentErrorMessage)
            }
            .alert("Re-align Failed", isPresented: cueRealignErrorPresented) {
                Button("OK", role: .cancel) {
                    cueRealignErrorMessage = ""
                }
            } message: {
                Text(cueRealignErrorMessage)
            }
            .confirmationDialog(
                "\(subtitleMismatchCount) subtitle\(subtitleMismatchCount == 1 ? "" : "s") differ from note text",
                isPresented: $isShowingSubtitleMismatchDialog,
                titleVisibility: .visible
            ) {
                Button("Update subtitles to match note") {
                    syncSubtitlesToNote()
                }
                Button("Update note to match subtitles") {
                    syncNoteToSubtitles()
                }
                Button("Ignore", role: .cancel) {}
            } message: {
                Text("The subtitle text doesn't match the note for some lines. This can happen when alignment produces different characters than the original.")
            }
            .alert("AI Correction", isPresented: $isShowingLLMCorrectionError) {
                Button("Retry") {
                    llmCorrectionErrorMessage = ""
                    requestLLMCorrection()
                }
                Button("OK", role: .cancel) {
                    llmCorrectionErrorMessage = ""
                }
            } message: {
                Text(llmCorrectionErrorMessage)
            }
            .alert("", isPresented: $isShowingLLMChangePopover) {
                Button("Confirm") {
                    if let loc = llmChangePopoverLocation {
                        confirmLLMChange(at: loc)
                    }
                }
                Button("Undo", role: .destructive) {
                    if let loc = llmChangePopoverLocation {
                        rejectLLMChange(at: loc)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(llmChangePopoverText)
            }
            .alert("Re-run AI Correction?", isPresented: $isShowingLLMRerunConfirm) {
                Button("Re-run", role: .destructive) {
                    requestLLMCorrection()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This note already has corrections applied. Re-running will replace them.")
            }
            // Auto-segmentation confirm dialog disabled — see requestAutoSegConfirm in
            // ReadView+Persistence.swift for re-enable instructions.
            // .alert(
            //     "Run automatic segmentation?",
            //     isPresented: Binding(
            //         get: { pendingAutoSegQueue.isEmpty == false },
            //         set: { isPresented in
            //             if isPresented == false, let head = pendingAutoSegQueue.first {
            //                 cancelPendingAutoSeg(head)
            //             }
            //         }
            //     ),
            //     presenting: pendingAutoSegQueue.first
            // ) { request in
            //     Button("Confirm") { commitPendingAutoSeg(request) }
            //     Button("Cancel", role: .cancel) { cancelPendingAutoSeg(request) }
            // } message: { request in
            //     let pendingNote = pendingAutoSegQueue.count > 1
            //         ? "\n(\(pendingAutoSegQueue.count - 1) more queued)"
            //         : ""
            //     let diskNote = activeNoteID.flatMap { notesStore.note(withID: $0) }
            //     let diskSegs = diskNote?.segments?.count ?? 0
            //     let diskFuri = diskNote?.segments?.reduce(0) { $0 + ($1.furigana?.count ?? 0) } ?? 0
            //     let memSegs = segments?.count ?? 0
            //     let memFuri = furiganaBySegmentLocation.count
            //     Text("\(request.reason)\ndisk: \(diskSegs)seg/\(diskFuri)furi  mem: \(memSegs)seg/\(memFuri)furi\(pendingNote)")
            // }
    }

    var lifecycleReadView: some View {
        selectionLifecycleReadView
            .onDisappear {
                // Flushes any pending edit persistence before leaving the read screen.
                segmentationRefreshTask?.cancel()
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
            .onChange(of: text) { oldText, newText in
                // Suppress this handler when the change was the load-handler's own assignment.
                // SwiftUI runs onChange after isLoadingSelectedNote has already been cleared, so
                // a flag isn't enough — match the actual value the loader wrote.
                if let snapshot = lastLoadedTextSnapshot, snapshot == newText {
                    lastLoadedTextSnapshot = nil
                    return
                }
                // Re-resolves cue highlight ranges only when the line count changes, since cue-to-line
                // mapping is stable for in-line edits but shifts whenever lines are added or removed.
                if audioAttachmentCues.isEmpty == false {
                    let oldLineCount = oldText.components(separatedBy: .newlines).count
                    let newLineCount = newText.components(separatedBy: .newlines).count
                    if oldLineCount != newLineCount {
                        audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(
                            for: audioAttachmentCues,
                            in: newText
                        )
                    }
                }
                if isEditMode {
                    // Preserve user customizations (splits/merges/furigana) in segments whose
                    // surfaces still match a prefix/suffix of the edited content. Only the
                    // diverging middle becomes an unsegmented stub; the segmenter will revisit
                    // it when edit mode exits.
                    let reconciled: [SegmentRange]?
                    if let existing = segments {
                        reconciled = reconcileSegments(existing, to: newText)
                    } else {
                        reconciled = nil
                    }
                    segments = reconciled
                    illegalMergeBoundaryLocation = nil
                    illegalMergeFlashTask?.cancel()
                    segmentationRefreshTask?.cancel()
                    furiganaComputationTask?.cancel()
                    segmentLatticeEdges = []
                    segmentEdges = []
                    segmentRanges = []
                    selectedSegmentLocation = nil
                    selectedHighlightRangeOverride = nil
                    selectedBounds = nil
                    SegmentLookupSheet.shared.dismissPopover()
                    // Rebuild the runtime furigana map from the reconciled segments so annotations
                    // in surviving regions are not dropped and their absolute offsets reflect any
                    // shift caused by length changes in the edited region.
                    if let reconciled {
                        let restored = furiganaFromSegmentRanges(reconciled)
                        furiganaBySegmentLocation = restored.byLocation
                        furiganaLengthBySegmentLocation = restored.lengthByLocation
                    } else {
                        furiganaBySegmentLocation = [:]
                        furiganaLengthBySegmentLocation = [:]
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
            .onChange(of: isEditMode) { _, editing in
                if editing {
                    // Hand the CT read view's live scroll position to the editor. The CT
                    // renderer reports into the reference-type memo (not @State) while the
                    // user scrolls in view mode; this is the one moment the shared offset
                    // needs to catch up so RichTextEditor's applyExternalScrollIfNeeded
                    // restores the same position. Without this, the editor opened at a stale
                    // offset (last edit position or last sheet adjustment).
                    sharedScrollOffsetY = readScrollOffsetMemo.value
                    // Suspends in-progress furigana / segmentation work and clears transient
                    // selection state. Note: we deliberately do NOT clear furiganaBySegmentLocation
                    // here. The renderer is gated by `isActive: isEditMode == false`, so it
                    // doesn't read the map during editing, and keeping the user's chosen
                    // readings in memory means we never have to "restore" them on exit.
                    // onChange(of: text) handles real text edits via reconcileSegments.
                    illegalMergeBoundaryLocation = nil
                    illegalMergeFlashTask?.cancel()
                    segmentationRefreshTask?.cancel()
                    furiganaComputationTask?.cancel()
                    segmentLatticeEdges = []
                    segmentEdges = []
                    segmentRanges = []
                    selectedSegmentLocation = nil
                    selectedHighlightRangeOverride = nil
                    selectedBounds = nil
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
            .onChange(of: segmenterRevision) { _, _ in
                if text.isEmpty == false, debugStartupSegmentationDiffs {
                    StartupTimer.measure("SegmentationDiffPrinter.printDiffs") {
                        SegmentationDiffPrinter.printDiffs(for: text, trieSegmenter: segmenter)
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
                if segments != nil {
                    StartupTimer.mark("scheduling furigana now that surfaceReadingData is ready")
                    scheduleFuriganaGeneration(for: text, edges: segmentEdges)
                } else {
                    StartupTimer.mark("no persisted segments, running full segmentation")
                    refreshSegmentationRanges()
                }

                // Resources just became ready. A lookup/split sheet opened while they were still
                // loading captured empty frequency maps and shows all-zero scores; re-install the
                // provider with the now-loaded `self` so the open readout fills in automatically.
                SegmentLookupSheet.shared.refreshOpenSheetFrequencyProvider { surface in
                    frequencyData(forSurface: surface)
                }
            }
            // The surface-reading/frequency map publishes in Stage 1, ahead of the full engine. When it
            // lands, fill in a split readout that opened during loading — without waiting for the trie.
            .onChange(of: frequencyDataReady) { _, ready in
                guard ready else { return }
                SegmentLookupSheet.shared.refreshOpenSheetFrequencyProvider { surface in
                    frequencyData(forSurface: surface)
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
                controller: audioController,
                cues: audioAttachmentCues,
                highlightRanges: audioAttachmentHighlightRanges,
                granularity: lyricsHighlightGranularity,
                segmentationRanges: segmentRanges,
                noteText: text,
                playbackHighlightRangeOverride: $playbackHighlightRangeOverride,
                activePlaybackCueIndex: $activePlaybackCueIndex
            )
        }
        .overlay(alignment: .topLeading) {
            // Pixel ruler is non-interactive and only drawn when its debug toggle is active.
            if debugPixelRuler {
                PixelRulerOverlayView()
            }
        }
        .overlay {
            if isShowingSubtitlePopup || isGeneratingLyricAlignment {
                subtitlePopupOverlay
            }
        }
        .overlay {
            if activeAudioAttachmentID != nil {
                LyricsView(
                    controller: audioController,
                    cues: audioAttachmentCues,
                    highlightRanges: audioAttachmentHighlightRanges,
                    furiganaBySegmentLocation: furiganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                    segmentationRanges: segmentRanges,
                    noteText: text,
                    attachmentID: activeAudioAttachmentID,
                    playbackHighlightRangeOverride: lyricsHighlightGranularity == .sentence ? nil : playbackHighlightRangeOverride,
                    granularity: lyricsHighlightGranularity,
                    onSegmentTapped: { location, rect, sourceView in
                        handleReadModeSegmentTap(location, tappedSegmentRect: rect, sourceView: sourceView)
                    },
                    onDismiss: {
                        isShowingLyricsView = false
                    },
                    onCueEdit: { edit in
                        applyLyricCueEdit(edit)
                    },
                    realigningCueIndex: realigningCueIndex
                )
                .opacity(isShowingLyricsView ? 1 : 0)
                .allowsHitTesting(isShowingLyricsView)
                .animation(.easeInOut(duration: 0.2), value: isShowingLyricsView)
            }
        }
        .sheet(isPresented: $isShowingSegmentList) {
            SegmentListView(
                text: text,
                edges: segmentEdges,
                latticeEdges: segmentLatticeEdges,
                dictionaryStore: dictionaryStore,
                sourceNoteID: activeNoteID,
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
        .fileImporter(
            isPresented: $isShowingSubtitlePicker,
            allowedContentTypes: subtitlePickerTarget.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch subtitlePickerTarget {
            case .audio: handleLyricAlignmentAudioSelection(result)
            case .subtitleFile: handleSubtitleFileSelection(result)
            }
        }
        // Lyric-button quick-load picker: one shot for audio + subtitle/textgrid. Multi-select so
        // the user can grab "song.mp3" and "song.srt" (or "song.TextGrid") together; the handler
        // sorts them by kind and imports in one pass.
        .fileImporter(
            isPresented: $isShowingLyricMediaPicker,
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
        .sheet(isPresented: $isShowingBreakdownSheet) {
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
                        kanjiReadingFallback: kanjiReadingFallback
                    )
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { isShowingBreakdownSheet = false }
                            }
                        }
                }
            }
        }
    }
}
