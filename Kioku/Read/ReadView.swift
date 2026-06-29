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
    // Observes the singleton so the renderer re-evaluates inFlightLineLocations
    // whenever the AI client publishes a new currentLineIndex during streaming.
    @ObservedObject var aiProgress = AICorrectionProgress.shared
    let segmenter: any TextSegmenting
    let dictionaryStore: DictionaryStore?
    let lexicon: Lexicon?
    let surfaceReadingData: SurfaceReadingDataMap
    let kanjiReadingFallback: KanjiReadingFallbackMap
    // Per-entry-propagated JPDB rank per surface. Frequency fallback for lookup/split-editor pieces
    // whose surface carries no rank in surface_readings (notably kana writings). See frequencyData(forSurface:).
    let frequencyRankBySurface: FrequencyRankMap
    // True once the surface-reading/frequency map is loaded (published early, before the full engine).
    // Drives the split readout's loading state and its refresh when frequency data arrives.
    let frequencyDataReady: Bool
    let segmenterRevision: Int
    let readResourcesReady: Bool
    // (entryID, surface, reading, sublatticePaths) — carries pre-computed data from the lookup sheet.
    var onOpenWordDetail: ((Int64, String, String?, [[String]]) -> Void)? = nil
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

    // Opt-in Japanese theme; gates the warm-paper reading pane fill (see ReadView+Editor).
    @AppStorage(Theme.storageKey) var japaneseTheme = false
    @AppStorage(TypographySettings.textSizeKey) var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(TypographySettings.customFuriganaSizeEnabledKey) var customFuriganaSizeEnabled: Bool = false
    @AppStorage(TypographySettings.furiganaSizeKey) var furiganaSize = TypographySettings.defaultFuriganaSize
    @AppStorage(TokenColorSettings.enabledKey) var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage(TokenColorSettings.highlightColorKey) var highlightHex: String = TokenColorSettings.defaultHighlightHex
    @AppStorage("kioku.settings.showFurigana") var isFuriganaVisible = true
    @AppStorage("kioku.settings.colorAlternation") var isColorAlternationEnabled = true
    @AppStorage("kioku.settings.highlightUnknown") var isHighlightUnknownEnabled = false
    @AppStorage("kioku.settings.applyGlobally") var shouldApplyChangesGlobally = true
    @AppStorage("kioku.settings.lineWrapping") var isLineWrappingEnabled = true
    @AppStorage("kioku.settings.rubySpacing") var isRubySpacingEnabled = true
    @AppStorage("kioku.settings.favoritedGlow") var isFavoritedGlowEnabled = false
    @AppStorage(DebugSettings.pixelRulerKey) var debugPixelRuler: Bool = false
    @AppStorage(DebugSettings.furiganaRectsKey) var debugFuriganaRects: Bool = false
    @AppStorage(DebugSettings.headwordRectsKey) var debugHeadwordRects: Bool = false
    @AppStorage(DebugSettings.headwordLineBandsKey) var debugHeadwordLineBands: Bool = false
    @AppStorage(DebugSettings.furiganaLineBandsKey) var debugFuriganaLineBands: Bool = false
    @AppStorage(DebugSettings.headwordLineNumbersKey) var debugHeadwordLineNumbers: Bool = false
    @AppStorage(DebugSettings.rubyLineNumbersKey) var debugRubyLineNumbers: Bool = false
    @AppStorage(DebugSettings.bisectorHeadwordKey) var debugBisectorHeadword: Bool = false
    @AppStorage(DebugSettings.bisectorFuriganaKey) var debugBisectorFurigana: Bool = false
    @AppStorage(DebugSettings.envelopeRectsKey) var debugEnvelopeRects: Bool = false
    @AppStorage(DebugSettings.leftInsetGuideKey) var debugLeftInsetGuide: Bool = false
    // CoreText renderer is now the only path; gate hard-wired below.
    // @AppStorage(DebugSettings.useCoreTextRendererKey) private var useCoreTextRenderer: Bool = true
    @AppStorage(DebugSettings.startupSegmentationDiffsKey) var debugStartupSegmentationDiffs: Bool = false

    @State var customTitle = ""
    @State var fallbackTitle = ""
    @State var titleDraft = ""
    @State var isShowingTitleAlert = false
    @State var text = ""
    @State var segmentLatticeEdges: [LatticeEdge] = []
    @State var segmentEdges: [LatticeEdge] = []
    @State var segmentRanges: [Range<String.Index>] = []
    // Cache for the favorited-glow set so it isn't recomputed (deinflection sweep) on every body eval.
    @State var favoritedGlowMemo = FavoritedGlowMemo()
    @State var unknownSegmentLocations: Set<Int> = []
    @State var selectedSegmentLocation: Int?
    @State var selectedHighlightRangeOverride: NSRange?
    @State var selectedBounds: ClosedRange<Int>?
    @State var transientBlankReadingSegmentLocation: Int?
    @State var segments: [SegmentRange]?
    // True once the user has manually changed this note's segmentation (merge/split) or its
    // readings (pin/unpin furigana), or applied an LLM correction. Drives the reset button's
    // enabled state. `segments != nil` can't stand in for this: import precompute persists the
    // *computed* segmentation to disk, so a freshly-loaded, never-edited note still has non-nil
    // segments. This flag is set only at genuine user-mutation funnels and cleared on note load
    // and reset, so it stays false for precomputed-but-unedited notes.
    @State var hasManualSegmentationEdits = false
    @State var furiganaBySegmentLocation: [Int: String] = [:]
    @State var furiganaLengthBySegmentLocation: [Int: Int] = [:]
    // Locations whose wide furigana entries came from the synthesis pass (per-character
    // concatenation, e.g. ものご for 物語 when the dict reading isn't yet loaded). Tracked
    // in-memory so a later recompute with a real dict-derived compound reading can replace
    // them. On note load this set is reconstructed by `performScheduleFuriganaGeneration`'s
    // pre-apply classifier, which marks any wide entry whose value matches a naive per-
    // character dict concat — precise enough to spare LLM pins (whose value diverges from
    // the concat) but aggressive enough to recover disk state poisoned by pre-gate code.
    @State var synthesizedFuriganaLocations: Set<Int> = []
    @State var furiganaComputationTask: Task<Void, Never>?
    @State var segmentationRefreshTask: Task<Void, Never>?
    @State var activeNoteID: UUID?
    @StateObject private var lyricsTranslationCache = LyricsTranslationCache()
    @State var isLoadingSelectedNote = false
    @State var isEditMode = false
    @State var isSheetSwipeTransitionActive = false
    @State var sharedScrollOffsetY: CGFloat = 0
    // Live mirror of the CT read view's scroll offset; snapshotted into sharedScrollOffsetY
    // when edit mode is entered. See ReadScrollOffsetMemo for why it's not @State itself.
    @State var readScrollOffsetMemo = ReadScrollOffsetMemo()
    // Extra contentInset.bottom currently injected into the read scroll view so the lookup
    // sheet can keep the selected segment visible even when it sits past the natural bottom
    // of the note. Tracked here so dismissal removes exactly what was added, regardless of
    // any other inset changes the scroll view's owner might have made in the meantime.
    @State var appliedSheetBottomInset: CGFloat = 0
    @State var isShowingSegmentList = false
    @State var isShowingDisplayOptions = false
    @State var isShowingFileImporter = false
    @State var isShowingSubtitlePopup = false
    @State var isShowingBreakdownSheet = false
    @State var isPerformingAudioTranscription = false
    @State var isGeneratingLyricAlignment = false
    @State var isCancellingAlignment = false
    @State var alignmentCancellationToken = AlignmentCancellationToken()
    @State var audioTranscriptionErrorMessage = ""
    @State var lyricAlignmentErrorMessage = ""
    @State var lyricAlignmentProgressMessage = ""
    @State var lyricAlignmentSourceFilename = ""
    @State var alignmentResultSRT = ""
    @State var pendingSubtitleAudioURL: URL? = nil
    @State var pendingSubtitleAudioFilename = ""
    @State var pendingSubtitleFileURL: URL? = nil
    @State var pendingSubtitleFilename = ""
    @State var pendingSubtitleTextGridURL: URL? = nil
    @State var pendingSubtitleTextGridFilename = ""
    @State var isShowingSubtitlePicker = false
    @State var subtitlePickerTarget: SubtitlePickerTarget = .audio
    // Drives the lyric-button "nothing loaded yet" media picker (mp3 + srt + textgrid, multi-select).
    @State var isShowingLyricMediaPicker = false
    @State var illegalMergeBoundaryLocation: Int?
    @State var illegalMergeFlashTask: Task<Void, Never>?
    @State var audioController = AudioPlaybackController()
    // Cues carry their per-cue karaoke checkpoints inline (cue.checkpoints); there is no separate
    // timings state to keep in sync.
    @State var audioAttachmentCues: [SubtitleCue] = []
    @State var audioAttachmentHighlightRanges: [NSRange?] = []
    @State var playbackHighlightRangeOverride: NSRange?
    @State var activePlaybackCueIndex: Int? = nil
    @State var activeAudioAttachmentID: UUID? = nil
    // Cue index currently being re-aligned by the lyric view's in-place "fix word sweep"
    // control; nil when idle. Drives the per-cue spinner in the lyric editing row and
    // gates concurrent re-align requests to one at a time.
    @State var realigningCueIndex: Int? = nil
    // Surfaced in a dedicated alert when an in-place cue re-alignment fails, so the
    // failure doesn't ride in under the unrelated "Generate SRT Failed" title.
    @State var cueRealignErrorMessage = ""
    // Drives the lyric view's top "Re-align" action: a full from-scratch re-run of the CTC
    // pipeline over the attached audio (vs. the per-cue "fix word sweep"). The bar shows a
    // spinner + progress while this is true; the message carries the live percent.
    @State var isReAligningWholeNote = false
    @State var reAlignProgressMessage = ""
    // True while the lyric view is playing the isolated vocal stem instead of the original mix
    // (the "Vocals/Mix" toggle next to Re-align). ReadView swaps the AudioPlaybackController's
    // source in onChange; reset to false whenever the audio source could change underneath it
    // (attachment switch, re-align that regenerates the stem).
    @State var isListeningToStem = false

    @State var isShowingLyricsView = false
    @AppStorage(LyricsHighlightGranularity.storageKey) var lyricsHighlightGranularityRaw = LyricsHighlightGranularity.defaultValue.rawValue

    // Typed view of the granularity AppStorage, falling back to the default when the persisted
    // raw value pre-dates a new case being added.
    var lyricsHighlightGranularity: LyricsHighlightGranularity {
        LyricsHighlightGranularity(rawValue: lyricsHighlightGranularityRaw) ?? LyricsHighlightGranularity.defaultValue
    }
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
    // True once an LLM correction has actually been applied to the currently-loaded note.
    // Gates the "Re-run AI Correction?" confirm so it only warns about replacing prior
    // corrections — not on the first run. Reset when a note loads or corrections are cleared.
    // (Session-scoped: reloading a previously-corrected note starts fresh, so the first tap
    // after reload runs without the warning.)
    @State var hasAppliedLLMCorrectionForCurrentNote = false
    @State var pendingAutoSegQueue: [PendingAutoSegRequest] = []
    // Records the value that loadSelectedNoteIfNeeded just wrote into `text` so the deferred
    // SwiftUI .onChange(of: text) handler can recognize the load-assignment and skip its
    // recompute/persist work. Without this guard every note open triggers a redundant second
    // refreshSegmentationRanges right after the explicit one in the load path.
    @State var lastLoadedTextSnapshot: String?
    // Debug overlay: disk/mem segment + furigana counts shown for ~2s on every note load,
    // so we can see at a glance whether persisted data round-trips correctly.
    @State var loadInfoToastMessage: String?
    @State var loadInfoToastClearTask: Task<Void, Never>?
    @AppStorage(LLMSettings.useLLMKey) private var llmUseLLM = false
    @AppStorage(LLMSettings.stubResponseKey) private var llmStubResponse = ""
    // Keys themselves live in the Keychain; the revision counter is the reactive
    // signal that a key was added or cleared in Settings.
    @AppStorage(LLMSettings.keysRevisionKey) private var llmKeysRevision = 0
    @Environment(\.scenePhase) var scenePhase

    // Initializes the read screen with the active note selection and shared read resources.
    init(
        selectedNote: Binding<Note?>,
        shouldActivateEditModeOnLoad: Binding<Bool> = .constant(false),
        segmenter: any TextSegmenting,
        dictionaryStore: DictionaryStore?,
        lexicon: Lexicon? = nil,
        surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap(),
        kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap(),
        frequencyRankBySurface: FrequencyRankMap = FrequencyRankMap(),
        frequencyDataReady: Bool = false,
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
        self.kanjiReadingFallback = kanjiReadingFallback
        self.frequencyRankBySurface = frequencyRankBySurface
        self.frequencyDataReady = frequencyDataReady
        self.segmenterRevision = segmenterRevision
        self.readResourcesReady = readResourcesReady
        self.onOpenWordDetail = onOpenWordDetail
        self.onActiveNoteChanged = onActiveNoteChanged
    }

    let prefersSheetDirectSegmentActions = true

    // Reactive equivalent of LLMSettings.isConfigured() — re-evaluates when any LLM
    // setting changes. Reading llmKeysRevision ties body invalidation to key edits;
    // the actual presence check goes to the Keychain. Internal so the toolbar and
    // title-row extensions can hide their LLM buttons until a provider is available.
    // Apple Intelligence requires no key, so it counts as configured whenever the
    // on-device model is present and ready, regardless of remote key state.
    var isLLMConfigured: Bool {
        _ = llmKeysRevision
        if llmUseLLM {
            let provider = LLMSettings.activeProvider()
            if provider == .appleIntelligence {
                return AppleIntelligenceAvailability.isAvailable
            }
            return LLMSettings.apiKey(for: provider) != nil
        } else {
            return llmStubResponse.isEmpty == false
        }
    }

    // The Note currently visible in Read, resolved against the canonical store. ReadView's
    // load handler consumes the `selectedNote` binding (clears it once `activeNoteID` is
    // populated), so anything that wants the displayed note has to look it up here. Used by
    // the breakdown sheet so it shows the right note regardless of how it got loaded
    // (selection from Notes, restored from `lastActiveNoteID`, fresh OCR import).
    var currentDisplayedNote: Note? {
        if let id = activeNoteID, let stored = notesStore.note(withID: id) {
            return stored
        }
        // Unsaved buffer fallback: a fresh note created via "New Note" hasn't been added
        // to the store yet. We still want the breakdown sheet to work against the typed
        // text — synthesize a transient Note carrying whatever's in the editor right now.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return Note(id: activeNoteID ?? UUID(), content: text)
        }
        return nil
    }

    var body: some View {
        alertingReadView
    }

}

#Preview {
    ReadView(selectedNote: .constant(nil), shouldActivateEditModeOnLoad: .constant(false), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, segmenterRevision: 0, readResourcesReady: false)
        .environmentObject(NotesStore())
}
