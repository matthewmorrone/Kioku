import PhotosUI
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// Provides the primary reading and editing surface for an active note.
struct ReadView: View {
    @Binding var selectedNote: Note?
    @Binding var shouldActivateEditModeOnLoad: Bool
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject var wordsStore: WordsStore
    let segmenter: any TextSegmenting
    let dictionaryStore: DictionaryStore?
    let lexicon: Lexicon?
    let surfaceReadingData: SurfaceReadingDataMap
    let segmenterRevision: Int
    let readResourcesReady: Bool
    // (entryID, surface, reading, sublatticePaths) — carries pre-computed data from the lookup sheet.
    var onOpenWordDetail: ((Int64, String, String?, [[String]]) -> Void)? = nil
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(TokenColorSettings.enabledKey) private var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage("kioku.settings.showFurigana") var isFuriganaVisible = true
    @AppStorage("kioku.settings.colorAlternation") var isColorAlternationEnabled = true
    @AppStorage("kioku.settings.highlightUnknown") var isHighlightUnknownEnabled = false
    @AppStorage("kioku.settings.applyGlobally") var shouldApplyChangesGlobally = true
    @AppStorage("kioku.settings.lineWrapping") var isLineWrappingEnabled = true
    @AppStorage(DebugSettings.pixelRulerKey) private var debugPixelRuler: Bool = false
    @AppStorage(DebugSettings.furiganaRectsKey) private var debugFuriganaRects: Bool = false
    @AppStorage(DebugSettings.headwordRectsKey) private var debugHeadwordRects: Bool = false
    @AppStorage(DebugSettings.headwordLineBandsKey) private var debugHeadwordLineBands: Bool = false
    @AppStorage(DebugSettings.furiganaLineBandsKey) private var debugFuriganaLineBands: Bool = false
    @AppStorage(DebugSettings.bisectorsKey) private var debugBisectors: Bool = false
    @AppStorage(DebugSettings.envelopeRectsKey) private var debugEnvelopeRects: Bool = false
    @AppStorage(DebugSettings.startupSegmentationDiffsKey) private var debugStartupSegmentationDiffs: Bool = false

    @State var customTitle = ""
    @State var fallbackTitle = ""
    @State private var titleDraft = ""
    @State private var isShowingTitleAlert = false
    @State var text = ""
    @State var segmentLatticeEdges: [LatticeEdge] = []
    @State var segmentEdges: [LatticeEdge] = []
    @State var segmentRanges: [Range<String.Index>] = []
    @State var unknownSegmentLocations: Set<Int> = []
    @State var selectedSegmentLocation: Int?
    @State var selectedHighlightRangeOverride: NSRange?
    @State var selectedBounds: ClosedRange<Int>?
    @State var transientBlankReadingSegmentLocation: Int?
    @State var segments: [SegmentRange]?
    @State var furiganaBySegmentLocation: [Int: String] = [:]
    @State var furiganaLengthBySegmentLocation: [Int: Int] = [:]
    @State var furiganaComputationTask: Task<Void, Never>?
    @State var segmentationRefreshTask: Task<Void, Never>?
    @State var activeNoteID: UUID?
    @StateObject private var lyricsTranslationCache = LyricsTranslationCache()
    @State var isLoadingSelectedNote = false
    @State var isEditMode = false
    @State var isSheetSwipeTransitionActive = false
    @State var sharedScrollOffsetY: CGFloat = 0
    @State var isShowingSegmentList = false
    @State var isShowingDisplayOptions = false
    @State var isShowingPhotoLibraryPicker = false
    @State var isShowingCameraPicker = false
    @State var isShowingFileImporter = false
    @State var isShowingSubtitlePopup = false
    @State var selectedOCRImageItem: PhotosPickerItem?
    @State var isPerformingOCRImport = false
    @State var isPerformingAudioTranscription = false
    @State var isGeneratingLyricAlignment = false
    @State var isCancellingAlignment = false
    @State var ocrImportErrorMessage = ""
    @State var audioTranscriptionErrorMessage = ""
    @State var lyricAlignmentErrorMessage = ""
    @State var lyricAlignmentProgressMessage = ""
    @State var lyricAlignmentSourceFilename = ""
    @State var alignmentResultSRT = ""
    @State var pendingSubtitleAudioURL: URL? = nil
    @State var pendingSubtitleAudioFilename = ""
    @State var pendingSubtitleFileURL: URL? = nil
    @State var pendingSubtitleFilename = ""
    @State var isShowingSubtitlePicker = false
    @State var subtitlePickerTarget: SubtitlePickerTarget = .audio
    @State var illegalMergeBoundaryLocation: Int?
    @State var illegalMergeFlashTask: Task<Void, Never>?
    @State var audioController = AudioPlaybackController()
    @State var audioAttachmentCues: [SubtitleCue] = []
    @State var audioAttachmentHighlightRanges: [NSRange?] = []
    @State var playbackHighlightRangeOverride: NSRange?
    @State var activePlaybackCueIndex: Int? = nil
    @State var activeAudioAttachmentID: UUID? = nil

    @State var isShowingLyricsView = false
    @AppStorage(LyricsDisplayStyle.storageKey) var lyricsDisplayStyleRaw = LyricsDisplayStyle.defaultValue.rawValue
    @State var isShowingSubtitleEditor = false
    @State var isShowingSubtitleMismatchDialog = false
    @State var subtitleMismatchCount = 0
    @State var isRequestingLLMCorrection = false
    @State var isShowingLLMCorrectionError = false
    @State var llmCorrectionErrorMessage = ""
    @State var llmCorrectionTask: Task<Void, Never>?
    @State var pendingLLMChangedLocations: Set<Int> = []
    // Subset of pendingLLMChangedLocations where only the furigana reading changed (surface unchanged).
    @State var pendingLLMChangedReadingLocations: Set<Int> = []
    @State var pendingLLMChangesByLocation: [Int: String] = [:]
    // Full segment snapshot captured just before applying an LLM result, used to revert individual changes.
    @State var preLLMSegmentEntries: [LLMSegmentEntry] = []
    @State var hasPendingLLMChanges = false
    @State var llmChangePopoverText: String = ""
    @State var llmChangePopoverLocation: Int? = nil
    @State var isShowingLLMChangePopover = false
    @State var isShowingLLMRerunConfirm = false
    @AppStorage(LLMSettings.useLLMKey) private var llmUseLLM = false 
    @AppStorage(LLMSettings.stubResponseKey) private var llmStubResponse = ""
    @AppStorage(LLMSettings.openAIKeyStorageKey) private var llmOpenAIKey = ""
    @AppStorage(LLMSettings.claudeKeyStorageKey) private var llmClaudeKey = ""
    @Environment(\.scenePhase) private var scenePhase

    // Initializes the read screen with the active note selection and shared read resources.
    init(
        selectedNote: Binding<Note?>,
        shouldActivateEditModeOnLoad: Binding<Bool> = .constant(false),
        segmenter: any TextSegmenting,
        dictionaryStore: DictionaryStore?,
        lexicon: Lexicon? = nil,
        surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap(),
        segmenterRevision: Int,
        readResourcesReady: Bool,
        onOpenWordDetail: ((Int64, String, String?, [[String]]) -> Void)? = nil,
        onActiveNoteChanged: ((UUID) -> Void)? = nil
    ) {
        _selectedNote = selectedNote
        _shouldActivateEditModeOnLoad = shouldActivateEditModeOnLoad
        self.segmenter = segmenter
        self.dictionaryStore = dictionaryStore
        self.lexicon = lexicon
        self.surfaceReadingData = surfaceReadingData
        self.segmenterRevision = segmenterRevision
        self.readResourcesReady = readResourcesReady
        self.onOpenWordDetail = onOpenWordDetail
        self.onActiveNoteChanged = onActiveNoteChanged
    }

    let prefersSheetDirectSegmentActions = true

    // Reactive equivalent of LLMSettings.isConfigured() — re-evaluates when any LLM setting changes.
    private var isLLMConfigured: Bool {
        if llmUseLLM {
            let key = llmOpenAIKey.isEmpty == false ? llmOpenAIKey : llmClaudeKey
            return key.isEmpty == false
        } else {
            return llmStubResponse.isEmpty == false
        }
    }

    var body: some View {
        alertingReadView
    }



    private var alertingReadView: some View {
        lifecycleReadView
            .alert("OCR Import Failed", isPresented: ocrImportErrorPresented) {
                Button("OK", role: .cancel) {
                    ocrImportErrorMessage = ""
                }
            } message: {
                Text(ocrImportErrorMessage)
            }
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
                            try? audioController.load(audioURL: url, cues: newCues)
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
    }

    private var lifecycleReadView: some View {
        selectionLifecycleReadView
            .onChange(of: selectedOCRImageItem) { _, newItem in
                guard let newItem else {
                    return
                }

                // Starts OCR import once the user has picked an image for recognition.
                Task {
                    await importTextFromSelectedOCRImage(newItem)
                }
            }
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

    private var selectionLifecycleReadView: some View {
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
                    // Clear stale segmentation state before scheduling persistence so the
                    // debounce snapshot captures the post-edit state (segments = nil).
                    // Without this ordering the snapshot captures pre-edit segments, then
                    // the nil assignment below causes the staleness guard to reject the write.
                    segments = nil
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
                    furiganaBySegmentLocation = [:]
                    furiganaLengthBySegmentLocation = [:]
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
                    // Suspends furigana computation while editing text.
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
                    furiganaBySegmentLocation = [:]
                    furiganaLengthBySegmentLocation = [:]
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

                // When segments are persisted and furigana is already loaded, nothing to do.
                // When segments exist but furigana is missing, generate it now that surfaceReadingData is ready.
                // Otherwise recompute full segmentation.
                if segments != nil {
                    if furiganaBySegmentLocation.isEmpty {
                        StartupTimer.mark("scheduling furigana for persisted segments (furigana missing)")
                        scheduleFuriganaGeneration(for: text, edges: segmentEdges)
                    }
                } else {
                    StartupTimer.mark("no persisted segments, running full segmentation")
                    refreshSegmentationRanges()
                }
            }
    }

    private var presentedReadView: some View {
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
                highlightRanges: audioAttachmentHighlightRanges,
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
                    onSegmentTapped: { location, rect, sourceView in
                        handleReadModeSegmentTap(location, tappedSegmentRect: rect, sourceView: sourceView)
                    },
                    onDismiss: {
                        isShowingLyricsView = false
                    }
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
        .sheet(isPresented: $isShowingCameraPicker) {
            CameraImagePicker(onImagePicked: { imageData in
                Task {
                    await importTextFromOCRImageData(imageData)
                }
            })
        }
        .photosPicker(
            isPresented: $isShowingPhotoLibraryPicker,
            selection: $selectedOCRImageItem,
            matching: .images,
            preferredItemEncoding: .automatic
        )
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
    }

    // Displays the editable note title at the top of the reading screen.
    private var titleView: some View {
        VStack(spacing: 8) {
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    titleDraft = resolvedTitle
                    isShowingTitleAlert = true
                }

            HStack {
                Spacer()
                generateSRTButton
                ocrImportButton
                newNoteButton
            }
        }
        .padding(.vertical, 8)
        .alert("Edit Title", isPresented: $isShowingTitleAlert) {
            TextField("Title", text: $titleDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                customTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                flushPendingNotePersistenceIfNeeded()
            }
        }
    }

    // Keeps both read and edit renderers mounted so mode toggles are instant.
    private var editorView: some View {
        VStack(spacing: 8) {
            ZStack {
                FuriganaTextRenderer(
                    isActive: isEditMode == false,
                    isOverlayFrozen: isSheetSwipeTransitionActive,
                    text: text,
                    isLineWrappingEnabled: isLineWrappingEnabled,
                    segmentationRanges: readResourcesReady ? segmentRanges : [],
                    selectedSegmentLocation: selectedSegmentLocation,
                    blankSelectedSegmentLocation: transientBlankReadingSegmentLocation,
                    selectedHighlightRangeOverride: selectedHighlightRangeOverride,
                    playbackHighlightRangeOverride: playbackHighlightRangeOverride,
                    activePlaybackCueIndex: activePlaybackCueIndex,
                    illegalMergeBoundaryLocation: illegalMergeBoundaryLocation,
                    furiganaBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                    furiganaLengthBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                    isVisualEnhancementsEnabled: readResourcesReady,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    unknownSegmentLocations: unknownSegmentLocations,
                    changedSegmentLocations: pendingLLMChangedLocations,
                    changedReadingLocations: pendingLLMChangedReadingLocations,
                    customEvenSegmentColorHex: customTokenColorsEnabled ? tokenColorAHex : "",
                    customOddSegmentColorHex: customTokenColorsEnabled ? tokenColorBHex : "",
                    debugFuriganaRects: debugFuriganaRects,
                    debugHeadwordRects: debugHeadwordRects,
                    debugHeadwordLineBands: debugHeadwordLineBands,
                    debugFuriganaLineBands: debugFuriganaLineBands,
                    debugBisectors: debugBisectors,
                    debugEnvelopeRects: debugEnvelopeRects,
                    externalContentOffsetY: sharedScrollOffsetY,
                    onScrollOffsetYChanged: { newOffsetY in
                        sharedScrollOffsetY = newOffsetY
                    },
                    onSegmentTapped: { tappedSegmentLocation, tappedSegmentRect, sourceView in
                        handleReadModeSegmentTap(
                            tappedSegmentLocation,
                            tappedSegmentRect: tappedSegmentRect,
                            sourceView: sourceView
                        )
                    },
                    textSize: $textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    furiganaGap: furiganaGap
                )
                .opacity(isEditMode ? 0 : 1)
                .allowsHitTesting(isEditMode == false)
                .animation(.default, value: isEditMode)

                RichTextEditor(
                    text: $text,
                    isLineWrappingEnabled: isLineWrappingEnabled,
                    segmentationRanges: segmentRanges,
                    furiganaBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                    furiganaLengthBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                    isVisualEnhancementsEnabled: readResourcesReady,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    segmenter: segmenter,
                    isEditMode: isEditMode,
                    externalContentOffsetY: sharedScrollOffsetY,
                    onScrollOffsetYChanged: { newOffsetY in
                        sharedScrollOffsetY = newOffsetY
                    },
                    textSize: $textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    furiganaGap: furiganaGap,
                    debugHeadwordLineBands: debugHeadwordLineBands,
                    debugFuriganaLineBands: debugFuriganaLineBands
                )
                .opacity(isEditMode ? 1 : 0)
                .allowsHitTesting(isEditMode)
                .animation(.default, value: isEditMode)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isEditMode ? Color(.systemBackground) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isEditMode ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.3),
                    lineWidth: isEditMode ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .animation(.default, value: isEditMode)
    }

}

#Preview {
    ReadView(selectedNote: .constant(nil), shouldActivateEditModeOnLoad: .constant(false), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, segmenterRevision: 0, readResourcesReady: false)
        .environmentObject(NotesStore())
}
