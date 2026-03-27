import PhotosUI
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
    let segmenter: Segmenter
    let dictionaryStore: DictionaryStore?
    let lexicon: Lexicon?
    let readingBySurface: [String: String]
    let readingCandidatesBySurface: [String: [String]]
    let frequencyDataBySurface: [String: [String: FrequencyData]]
    let segmenterRevision: Int
    let readResourcesReady: Bool
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

    @AppStorage(TypographySettings.textSizeKey)
    private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey)
    private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey)
    private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey)
    private var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(TokenColorSettings.enabledKey)
    private var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey)
    private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey)
    private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage("kioku.settings.showFurigana")
    private var isFuriganaVisible = true
    @AppStorage("kioku.settings.colorAlternation")
    private var isColorAlternationEnabled = true
    @AppStorage("kioku.settings.highlightUnknown")
    private var isHighlightUnknownEnabled = false
    @AppStorage("kioku.settings.applyGlobally")
    var shouldApplyChangesGlobally = false
    @AppStorage("kioku.settings.lineWrapping")
    private var isLineWrappingEnabled = true
    @AppStorage(DebugSettings.pixelRulerKey)
    private var debugPixelRuler: Bool = false
    @AppStorage(DebugSettings.furiganaRectsKey)
    private var debugFuriganaRects: Bool = false
    @AppStorage(DebugSettings.headwordRectsKey)
    private var debugHeadwordRects: Bool = false
    @AppStorage(DebugSettings.headwordLineBandsKey)
    private var debugHeadwordLineBands: Bool = false
    @AppStorage(DebugSettings.furiganaLineBandsKey)
    private var debugFuriganaLineBands: Bool = false

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
    @State var segments: [SegmentRange]?
    @State var furiganaBySegmentLocation: [Int: String] = [:]
    @State var furiganaLengthBySegmentLocation: [Int: Int] = [:]
    @State var furiganaComputationTask: Task<Void, Never>?
    @State var pendingPersistenceTask: Task<Void, Never>?
    @State var activeNoteID: UUID?
    @State var isLoadingSelectedNote = false
    @State var isEditMode = false
    @State var isSheetSwipeTransitionActive = false
    @State var sharedScrollOffsetY: CGFloat = 0
    @State private var isShowingSegmentList = false
    @State var wordDetailWord: SavedWord?
    @State private var isShowingDisplayOptions = false
    @State var isShowingPhotoLibraryPicker = false
    @State var isShowingCameraPicker = false
    @State var isShowingAudioFileImporter = false
    @State var selectedOCRImageItem: PhotosPickerItem?
    @State var isPerformingOCRImport = false
    @State var isPerformingAudioTranscription = false
    @State var ocrImportErrorMessage = ""
    @State var audioTranscriptionErrorMessage = ""
    @State var illegalMergeBoundaryLocation: Int?
    @State var illegalMergeFlashTask: Task<Void, Never>?
    @StateObject var audioController = AudioPlaybackController()
    @State var audioAttachmentCues: [SubtitleCue] = []
    @State var audioAttachmentHighlightRanges: [NSRange?] = []
    @State var activeAudioAttachmentID: UUID? = nil
    @State private var isShowingSubtitleEditor = false
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
        segmenter: Segmenter,
        dictionaryStore: DictionaryStore?,
        lexicon: Lexicon? = nil,
        readingBySurface: [String: String],
        readingCandidatesBySurface: [String: [String]],
        frequencyDataBySurface: [String: [String: FrequencyData]] = [:],
        segmenterRevision: Int,
        readResourcesReady: Bool,
        onActiveNoteChanged: ((UUID) -> Void)? = nil
    ) {
        _selectedNote = selectedNote
        _shouldActivateEditModeOnLoad = shouldActivateEditModeOnLoad
        self.segmenter = segmenter
        self.dictionaryStore = dictionaryStore
        self.lexicon = lexicon
        self.readingBySurface = readingBySurface
        self.readingCandidatesBySurface = readingCandidatesBySurface
        self.frequencyDataBySurface = frequencyDataBySurface
        self.segmenterRevision = segmenterRevision
        self.readResourcesReady = readResourcesReady
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
        NavigationStack {
            titleView
            VStack(spacing: 10) {
                editorView
                // Shows playback controls when the active note has an audio attachment with cues loaded.
                if audioAttachmentCues.isEmpty == false {
                    AudioPlayerBar(
                        controller: audioController,
                        highlightRange: $selectedHighlightRangeOverride,
                        onEditSubtitles: { isShowingSubtitleEditor = true }
                    )
                }
                toolbarButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .toolbar(.visible, for: .tabBar)
        .overlay(alignment: .topLeading) {
            // Pixel ruler is non-interactive and only drawn when its debug toggle is active.
            if debugPixelRuler {
                PixelRulerOverlayView()
            }
        }
        .sheet(item: $wordDetailWord) { word in
            // WordDetailView reads wordListsStore via @EnvironmentObject inherited from ContentView.
            NavigationStack {
                WordDetailView(word: word, dictionaryStore: dictionaryStore)
                    .environmentObject(wordsStore)
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
            isPresented: $isShowingAudioFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            handleAudioImportSelection(result)
        }
        .onAppear {
            // Syncs editor state when this screen first appears.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: selectedNote?.id) { _, _ in
            // Syncs editor state when Notes tab selects a different note.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: audioController.activeCueIndex) { _, newIndex in
            // Resolves the precomputed highlight range for the newly active cue.
            guard let newIndex, newIndex < audioAttachmentHighlightRanges.count else {
                selectedHighlightRangeOverride = nil
                return
            }
            selectedHighlightRangeOverride = audioAttachmentHighlightRanges[newIndex]
        }
        .onChange(of: text) { oldText, newText in
            // Persists edits as content changes.
            scheduleCurrentNotePersistenceIfNeeded()
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
                segments = nil
                illegalMergeBoundaryLocation = nil
                illegalMergeFlashTask?.cancel()
                // Clears stale range state while editing so view-mode reactivation never reads mismatched ranges.
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
                return
            }
            // Recomputes segments only after full read resources are ready.
            if readResourcesReady && isEditMode == false {
                refreshSegmentationRanges()
            }
        }
        .onChange(of: isEditMode) { _, editing in
            if editing {
                // Suspends furigana computation while editing text.
                illegalMergeBoundaryLocation = nil
                illegalMergeFlashTask?.cancel()
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
            } else if readResourcesReady {
                flushPendingNotePersistenceIfNeeded()
                // Recomputes once when returning to view mode so furigana matches latest text.
                refreshSegmentationRanges()
            }
        }
        .onChange(of: segmenterRevision) { _, _ in
            // When segments are persisted and furigana is already loaded, nothing to do.
            // When segments exist but furigana is missing, generate it now that readingBySurface is ready.
            // Otherwise recompute full segmentation.
            if segments != nil {
                if furiganaBySegmentLocation.isEmpty {
                    scheduleFuriganaGeneration(for: text, edges: segmentEdges)
                }
            } else {
                refreshSegmentationRanges()
            }
        }
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
            flushPendingNotePersistenceIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Flushes pending edits when the app moves to background so in-flight debounce tasks
            // are not lost when the process is killed (e.g. during a Xcode rebuild).
            if newPhase == .background {
                flushPendingNotePersistenceIfNeeded()
            }
        }
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
                    initialCues: audioAttachmentCues
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

    // Displays the editable note title at the top of the reading screen.
    private var titleView: some View {
        ZStack {
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold))
                .onTapGesture {
                    titleDraft = resolvedTitle
                    isShowingTitleAlert = true
                }
            Spacer()
            HStack {
                Spacer()
                // audioTranscriptionButton
                ocrImportButton
                newNoteButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                    selectedHighlightRangeOverride: selectedHighlightRangeOverride,
                    illegalMergeBoundaryLocation: illegalMergeBoundaryLocation,
                    furiganaBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                    furiganaLengthBySegmentLocation: readResourcesReady && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                    isVisualEnhancementsEnabled: readResourcesReady,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    unknownSegmentLocations: unknownSegmentLocations,
                    changedSegmentLocations: pendingLLMChangedLocations,
                    changedReadingLocations: pendingLLMChangedReadingLocations,
                    segmenter: segmenter,
                    customEvenSegmentColorHex: customTokenColorsEnabled ? tokenColorAHex : "",
                    customOddSegmentColorHex: customTokenColorsEnabled ? tokenColorBHex : "",
                    debugFuriganaRects: debugFuriganaRects,
                    debugHeadwordRects: debugHeadwordRects,
                    debugHeadwordLineBands: debugHeadwordLineBands,
                    debugFuriganaLineBands: debugFuriganaLineBands,
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

                RichTextEditor(
                    text: $text,
                    isLineWrappingEnabled: isLineWrappingEnabled,
                    segmentationRanges: readResourcesReady ? segmentRanges : [],
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
    }

    // Renders action buttons for segmentation and display controls.
    private var toolbarButtons: some View {
        HStack {
            Spacer()
            llmCorrectionButton
            resetButton
            segmentListButton
            furiganaButton
            editModeButton
        }
        // .padding(.horizontal, 8)
    }

    // Triggers an LLM correction request for the current note's segmentation and readings.
    // While changes are pending, acts as a confirm button (sparkles + checkmark overlay).
    // Only enabled when a provider key is configured in Settings and the note is in read mode.
    private var llmCorrectionButton: some View {
        Button {
            if isRequestingLLMCorrection {
                cancelLLMCorrection()
            } else if hasPendingLLMChanges {
                // Sparkle+checkmark = confirm all pending changes.
                confirmLLMChanges()
            } else if segments != nil {
                // Note already has corrections applied — confirm before re-running.
                isShowingLLMRerunConfirm = true
            } else {
                requestLLMCorrection()
            }
        } label: {
            Group {
                if isRequestingLLMCorrection {
                    ZStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7, weight: .semibold))
                    }
                } else if hasPendingLLMChanges {
                    // Sparkles with a checkmark badge signals "confirm these AI changes".
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .offset(x: 4, y: 4)
                    }
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(hasPendingLLMChanges ? Color.green : Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Circle().fill(hasPendingLLMChanges ? Color.green.opacity(0.15) : Color(.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 1.0)
        .accessibilityLabel(hasPendingLLMChanges ? "Confirm AI Changes" : (isRequestingLLMCorrection ? "Cancel AI Correction" : "Request AI Correction"))
    }

    // Resets custom segment segmentation back to computed segmentation.
    // While LLM changes are pending, shows a red X badge to signal "reject all AI changes".
    private var resetButton: some View {
        Button {
            resetSegmentationToComputed()
        } label: {
            Group {
                if hasPendingLLMChanges {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .offset(x: 4, y: 4)
                    }
                    .foregroundStyle(Color.red)
                } else {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(segments == nil ? Color.secondary.opacity(0.5) : Color.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(hasPendingLLMChanges ? Color.red.opacity(0.15) : Color(.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled((segments == nil && hasPendingLLMChanges == false) || isEditMode)
        .opacity((segments == nil && hasPendingLLMChanges == false) || isEditMode ? 0.5 : 0.7)
        .accessibilityLabel(hasPendingLLMChanges ? "Reject AI Changes" : "Reset Segmentation")
    }

    // Opens the segment list screen for split/merge actions synced to the paste area.
    private var segmentListButton: some View {
        Button {
            isShowingSegmentList = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    isEditMode ? Color.secondary.opacity(0.5) : Color.secondary
                )
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 0.7)
        .accessibilityLabel("Show Segment List")
    }

    // Toggles whether furigana annotations render in the main paste area.
    private var furiganaButton: some View {
        furiganaButtonLabel
        .contentShape(Circle())
        .onTapGesture {
            guard isEditMode == false else {
                return
            }

            isFuriganaVisible.toggle()
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            guard isEditMode == false else {
                return
            }

            isShowingDisplayOptions = true
        }
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 0.8)
        .accessibilityLabel(isFuriganaVisible ? "Hide Furigana" : "Show Furigana")
        .accessibilityHint("Long press for display options")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isShowingDisplayOptions, arrowEdge: .bottom) {
            displayOptionsPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    // Renders the title-row button that creates and selects a fresh note for immediate editing.
    private var newNoteButton: some View {
        Button {
            flushPendingNotePersistenceIfNeeded()
            notesStore.addNote()
            guard let createdNote = notesStore.notes.first else {
                return
            }

            shouldActivateEditModeOnLoad = true
            selectedNote = createdNote
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Note")
    }

    // Renders the tappable furigana icon that also exposes display options on long press.
    private var furiganaButtonLabel: some View {
        Image(isFuriganaVisible ? "furigana.on" : "furigana.off")
            .renderingMode(.template)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isFuriganaVisible ? Color.accentColor : Color.secondary)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(Color(.tertiarySystemFill))
            )
    }

    // Presents display option toggles with persistent enabled-state styling.
    private var displayOptionsPopover: some View {
        VStack(spacing: 10) {
            displayOptionRow(
                title: "Apply Changes Globally",
                systemImage: "arrow.triangle.branch",
                isEnabled: shouldApplyChangesGlobally
            ) {
                shouldApplyChangesGlobally.toggle()
            }

            displayOptionRow(
                title: "Highlight Unknown",
                systemImage: isHighlightUnknownEnabled ? "questionmark.circle.fill" : "questionmark.circle",
                isEnabled: isHighlightUnknownEnabled
            ) {
                isHighlightUnknownEnabled.toggle()
            }

            displayOptionRow(
                title: "Segment Colors",
                systemImage: isColorAlternationEnabled ? "paintpalette.fill" : "paintpalette",
                isEnabled: isColorAlternationEnabled
            ) {
                isColorAlternationEnabled.toggle()
            }

            displayOptionRow(
                title: "Line Wrapping",
                systemImage: isLineWrappingEnabled ? "text.alignleft" : "arrow.right.to.line.compact",
                isEnabled: isLineWrappingEnabled
            ) {
                isLineWrappingEnabled.toggle()
            }
        }
        .padding(12)
        .frame(width: 270)
        .background(Color(.systemBackground))
    }

    // Renders one display-option row with a highlighted background while its toggle is enabled.
    private func displayOptionRow(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)

                Spacer(minLength: 0)

                if isEnabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isEnabled ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    // Uses one icon button whose visual treatment reflects active edit state.
    private var editModeButton: some View {
        Button {
            isEditMode.toggle()
        } label: {
            Image(systemName: "character.cursor.ibeam.ja")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEditMode ? Color.white : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isEditMode ? Color.accentColor : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isEditMode ? 1 : 0.7)
        .accessibilityLabel(isEditMode ? "Disable Edit Mode" : "Enable Edit Mode")
    }

}

#Preview {
    ReadView(selectedNote: .constant(nil), shouldActivateEditModeOnLoad: .constant(false), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, readingBySurface: [:], readingCandidatesBySurface: [:], segmenterRevision: 0, readResourcesReady: false)
        .environmentObject(NotesStore())
}
