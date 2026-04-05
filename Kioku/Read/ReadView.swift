import PhotosUI
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ReadViewFileImportTarget: Equatable {
    case transcriptionAudio
    case subtitleAudio
    case subtitleFile

    var allowedContentTypes: [UTType] {
        switch self {
        case .transcriptionAudio, .subtitleAudio:
            return [.audio, .mpeg4Audio, .mp3]
        case .subtitleFile:
            return [.subripText, .plainText]
        }
    }
}

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
    // (entryID, surface, reading) — reading is the resolved kana reading active in the lookup sheet.
    var onOpenWordDetail: ((Int64, String, String?) -> Void)? = nil
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
    @AppStorage(DebugSettings.startupSegmentationDiffsKey)
    private var debugStartupSegmentationDiffs: Bool = false

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
    @State var pendingPersistenceTask: Task<Void, Never>?
    @State var activeNoteID: UUID?
    @State var isLoadingSelectedNote = false
    @State var isEditMode = false
    @State var isSheetSwipeTransitionActive = false
    @State var sharedScrollOffsetY: CGFloat = 0
    @State private var isShowingSegmentList = false
    @State private var isShowingDisplayOptions = false
    @State var isShowingPhotoLibraryPicker = false
    @State var isShowingCameraPicker = false
    @State var activeFileImportTarget: ReadViewFileImportTarget? = nil
    @State var isShowingFileImporter = false
    @State var isShowingSubtitleSubmissionSheet = false
    @State var selectedOCRImageItem: PhotosPickerItem?
    @State var isPerformingOCRImport = false
    @State var isPerformingAudioTranscription = false
    @State var isGeneratingLyricAlignment = false
    @State var ocrImportErrorMessage = ""
    @State var audioTranscriptionErrorMessage = ""
    @State var lyricAlignmentErrorMessage = ""
    @State var subtitleImportErrorMessage = ""
    @State var lyricAlignmentProgressMessage = ""
    @State var lyricAlignmentSourceFilename = ""
    @State var pendingSubtitleAudioURL: URL? = nil
    @State var pendingSubtitleAudioFilename = ""
    @State var pendingSubtitleFileURL: URL? = nil
    @State var pendingSubtitleFilename = ""
    @State var illegalMergeBoundaryLocation: Int?
    @State var illegalMergeFlashTask: Task<Void, Never>?
    @State var audioController = AudioPlaybackController()
    @State var audioAttachmentCues: [SubtitleCue] = []
    @State var audioAttachmentHighlightRanges: [NSRange?] = []
    @State var playbackHighlightRangeOverride: NSRange?
    @State var activePlaybackCueIndex: Int? = nil
    @State var activeAudioAttachmentID: UUID? = nil

    @State var isShowingLyricsView = false
    @State var lyricsTranslationCache = LyricsTranslationCache()
    @AppStorage(LyricsDisplayStyle.storageKey) var lyricsDisplayStyleRaw = LyricsDisplayStyle.defaultValue.rawValue
    @State var isShowingSubtitleEditor = false
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
        onOpenWordDetail: ((Int64, String, String?) -> Void)? = nil,
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

    private var isShowingTranscriptionFileImporter: Binding<Bool> {
        Binding(
            get: {
                isShowingFileImporter && activeFileImportTarget == .transcriptionAudio
            },
            set: { isPresented in
                if isPresented == false, activeFileImportTarget == .transcriptionAudio {
                    isShowingFileImporter = false
                }
            }
        )
    }

    private var isShowingSubtitleFileImporter: Binding<Bool> {
        Binding(
            get: {
                guard isShowingFileImporter else {
                    return false
                }

                switch activeFileImportTarget {
                case .subtitleAudio, .subtitleFile:
                    return true
                default:
                    return false
                }
            },
            set: { isPresented in
                if isPresented == false {
                    switch activeFileImportTarget {
                    case .subtitleAudio, .subtitleFile:
                        isShowingFileImporter = false
                    default:
                        break
                    }
                }
            }
        )
    }

    // Builds the segment color map for the lyrics overlay using the same resolver as the read view.
    // Called only while the lyrics overlay is visible, so no persistent storage is needed.
    private var lyricsSegmentColorByLocation: [Int: UIColor] {
        guard readResourcesReady else { return [:] }
        let customEven = customTokenColorsEnabled ? UIColor(hexString: tokenColorAHex) : nil
        let customOdd  = customTokenColorsEnabled ? UIColor(hexString: tokenColorBHex) : nil
        let resolver = ReadTextStyleResolver(
            text: text,
            segmentationRanges: segmentRanges,
            textSize: textSize,
            lineSpacing: lineSpacing,
            kerning: kerning,
            isLineWrappingEnabled: isLineWrappingEnabled,
            isVisualEnhancementsEnabled: isColorAlternationEnabled,
            isColorAlternationEnabled: isColorAlternationEnabled,
            isHighlightUnknownEnabled: false,
            unknownSegmentLocations: [],
            changedSegmentLocations: [],
            changedReadingLocations: [],
            customEvenSegmentColor: customEven,
            customOddSegmentColor: customOdd
        )
        return resolver.makePayload().segmentForegroundByLocation
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
            .alert("Generate SRT Failed", isPresented: lyricAlignmentErrorPresented) {
                Button("OK", role: .cancel) {
                    lyricAlignmentErrorMessage = ""
                }
            } message: {
                Text(lyricAlignmentErrorMessage)
            }
            .alert("Subtitle Import Failed", isPresented: subtitleImportErrorPresented) {
                Button("OK", role: .cancel) {
                    subtitleImportErrorMessage = ""
                }
            } message: {
                Text(subtitleImportErrorMessage)
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
                } else if readResourcesReady {
                    flushPendingNotePersistenceIfNeeded()
                    // Recomputes once when returning to view mode so furigana matches latest text.
                    refreshSegmentationRanges()
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
        .sheet(isPresented: $isShowingSubtitleSubmissionSheet) {
            subtitleSubmissionSheet
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
        }
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
            if isGeneratingLyricAlignment {
                lyricAlignmentProgressOverlay
            }
        }
        .overlay {
            if isShowingLyricsView {
                LyricsView(
                    controller: audioController,
                    cues: audioAttachmentCues,
                    highlightRanges: audioAttachmentHighlightRanges,
                    furiganaBySegmentLocation: furiganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                    segmentColorByLocation: lyricsSegmentColorByLocation,
                    segmentationRanges: segmentRanges,
                    noteText: text,
                    displayStyle: LyricsDisplayStyle(rawValue: lyricsDisplayStyleRaw) ?? .appleMusic,
                    translationCache: lyricsTranslationCache,
                    onSegmentTapped: { tappedLocation in
                        handleReadModeSegmentTap(tappedLocation, tappedSegmentRect: nil, sourceView: nil)
                    },
                    onDismiss: {
                        isShowingLyricsView = false
                        audioController.resetToStart()
                    }
                )
                .transition(.opacity)
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
            isPresented: isShowingTranscriptionFileImporter,
            allowedContentTypes: activeFileImportTarget?.allowedContentTypes ?? [.data],
            allowsMultipleSelection: false
        ) { result in
            let target = activeFileImportTarget
            isShowingFileImporter = false
            activeFileImportTarget = nil
            handleFileImportSelection(result, target: target)
        }
    }

    private var subtitleSubmissionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Subtitles")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingSubtitleSubmissionSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 10) {
                subtitleSelectionButton(
                    title: "Audio File",
                    systemImage: "waveform",
                    value: pendingSubtitleAudioFilename.isEmpty ? "Choose..." : pendingSubtitleAudioFilename
                ) {
                    presentFileImporter(for: .subtitleAudio)
                }

                if pendingSubtitleAudioURL != nil {
                    Button("Remove Audio", role: .destructive) {
                        removePendingSubtitleAudioSelection()
                    }
                    .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                subtitleSelectionButton(
                    title: "Subtitle File",
                    systemImage: "captions.bubble",
                    value: pendingSubtitleFilename.isEmpty ? "Generate on submit" : pendingSubtitleFilename
                ) {
                    presentFileImporter(for: .subtitleFile)
                }

                if pendingSubtitleFileURL != nil {
                    Button("Remove Subtitle File", role: .destructive) {
                        pendingSubtitleFileURL = nil
                        pendingSubtitleFilename = ""
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isShowingSubtitleSubmissionSheet = false
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await submitPendingSubtitleSelection()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isGeneratingLyricAlignment {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Submit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingSubtitleAudioURL == nil || isGeneratingLyricAlignment)
            }
        }
        .padding(20)
        .interactiveDismissDisabled(isGeneratingLyricAlignment)
        .fileImporter(
            isPresented: isShowingSubtitleFileImporter,
            allowedContentTypes: activeFileImportTarget?.allowedContentTypes ?? [.data],
            allowsMultipleSelection: false
        ) { result in
            let target = activeFileImportTarget
            isShowingFileImporter = false
            activeFileImportTarget = nil
            handleFileImportSelection(result, target: target)
        }
    }

    private func subtitleSelectionButton(
        title: String,
        systemImage: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
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
                .animation(.default, value: isEditMode)

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

    // Renders action buttons for segmentation and display controls.
    private var toolbarButtons: some View {
        HStack {
            // ♪ button — only when audio and subtitles are both loaded.
            if audioController.duration > 0 && audioAttachmentCues.isEmpty == false {
                Button {
                    isShowingLyricsView.toggle()
                } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isShowingLyricsView ? Color(.systemOrange) : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lyrics")
            }
            Spacer()
            llmCorrectionButton
            resetButton
            segmentListButton
            furiganaButton
            editModeButton
        }
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

private struct AudioCueHighlightObserver: View {
    @ObservedObject var controller: AudioPlaybackController
    let highlightRanges: [NSRange?]
    @Binding var playbackHighlightRangeOverride: NSRange?
    @Binding var activePlaybackCueIndex: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                updateHighlight(for: controller.activeCueIndex, isPlaying: controller.isPlaying)
            }
            .onReceive(controller.$activeCueIndex.combineLatest(controller.$isPlaying)) { newIndex, isPlaying in
                updateHighlight(for: newIndex, isPlaying: isPlaying)
            }
    }

    private func updateHighlight(for cueIndex: Int?, isPlaying: Bool) {
        guard isPlaying, let cueIndex, cueIndex < highlightRanges.count else {
            playbackHighlightRangeOverride = nil
            activePlaybackCueIndex = nil
            return
        }

        activePlaybackCueIndex = cueIndex
        playbackHighlightRangeOverride = highlightRanges[cueIndex]
    }
}

#Preview {
    ReadView(selectedNote: .constant(nil), shouldActivateEditModeOnLoad: .constant(false), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, segmenterRevision: 0, readResourcesReady: false)
        .environmentObject(NotesStore())
}
