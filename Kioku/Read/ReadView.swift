import PhotosUI
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// Provides the primary reading and editing surface for an active note.
struct ReadView: View {
    @Binding var selectedNote: Note?
    @Binding var shouldActivateEditModeOnLoad: Bool
    // Set (via ReadNoteNavigation, by ContentView) when a tap on a Word Detail source note should
    // land here and jump to that word's first occurrence. Consumed once activeNoteID matches
    // target.noteID and cleared afterward — see jumpToPendingScrollSurfaceIfReady in
    // ReadView+Lifecycle.swift.
    @Binding var pendingScrollTarget: ReadNoteTarget?
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject var wordsStore: WordsStore
    // Powers the lookup popover/sheet star's long-press learned-state menu, mirroring the Words tab.
    // Read here (not just inside the breakdown sheet) so the title-row breakdown button can
    // show an activity indicator while a generation is running for the currently-open note.
    @EnvironmentObject var songBreakdownStore: SongBreakdownStore
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
    // Switches to the Settings tab and scrolls to/highlights the row with the given id (see
    // SettingsView's ScrollViewReader). Forwarded to LyricsView's "bring this setting into
    // focus" button (e.g. Background Audio).
    var onFocusSetting: ((String) -> Void)? = nil

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
    @AppStorage(TokenColorSettings.savedColorKey) var savedHex: String = TokenColorSettings.defaultSavedHex
    @AppStorage(TokenColorSettings.savedLearnedColorKey) var savedLearnedHex: String = TokenColorSettings.defaultSavedLearnedHex
    @AppStorage(TokenColorSettings.savedNotLearnedColorKey) var savedNotLearnedHex: String = TokenColorSettings.defaultSavedNotLearnedHex
    @AppStorage(TypographySettings.showFuriganaKey) var isFuriganaVisible = true
    // When on, furigana is suppressed for any segment whose word is marked learned or
    // mastered (see ReviewStore). Independent of isFuriganaVisible, which is the master
    // on/off switch — this only narrows what shows while furigana is otherwise on.
    @AppStorage("kioku.settings.hideFuriganaForKnownWords") var isFuriganaHiddenForKnownWords = false
    @AppStorage(TypographySettings.colorAlternationKey) var isColorAlternationEnabled = true
    @AppStorage("kioku.settings.highlightUnknown") var isHighlightUnknownEnabled = false
    @AppStorage("kioku.settings.applyGlobally") var shouldApplyChangesGlobally = true
    @AppStorage(TypographySettings.lineWrappingKey) var isLineWrappingEnabled = true
    @AppStorage(TypographySettings.rubySpacingKey) var isRubySpacingEnabled = true
    @AppStorage("kioku.settings.savedGlow") var isSavedHighlightEnabled = false
    // Independent per-category visibility toggles for Saved Highlight, set from its submenu.
    // Each category always renders in its own fixed color (see SettingsView+ThemeSection's
    // Saved Highlight color pickers) when its toggle is on — they aren't mutually exclusive,
    // so any combination (or all three) can show at once. A word's status is global (the same
    // everywhere it's saved), so there is no per-note "elsewhere" category.
    @AppStorage("kioku.settings.savedHighlight.showSaved") var isSavedHighlightShowingSaved = true
    @AppStorage("kioku.settings.savedHighlight.showLearned") var isSavedHighlightShowingLearned = true
    @AppStorage("kioku.settings.savedHighlight.showNotLearned") var isSavedHighlightShowingNotLearned = true
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
    @AppStorage(DebugSettings.startupSegmentationDiffsKey) var debugStartupSegmentationDiffs: Bool = false

    // Note-title editing state (custom title, fallback, rename-alert draft) — see TitleEditUIState.
    @State var titleEdit = TitleEditUIState()
    // The open note: text, source note id, segmentation, furigana maps, render caches — see
    // ReadDocumentState.
    @State var document = ReadDocumentState()
    // Segment selection for lookup (selected location/bounds, deferred tap, illegal-merge flash) —
    // see SegmentSelectionUIState.
    @State var segmentSelection = SegmentSelectionUIState()
    // Edit-mode transition + scroll-position state — see EditModeScrollUIState.
    @State var editModeScroll = EditModeScrollUIState()
    // Toolbar sheet/popover presentation flags — see ReadSheetsUIState.
    @State var readSheets = ReadSheetsUIState()
    // Subtitle/audio import UI state (transcription + alignment progress, staged picks,
    // import sheets/pickers) — see SubtitleImportUIState.
    @State var subtitleImport = SubtitleImportUIState()
    // Whole-note re-align UI state (progress/error, subtitle editor, mismatch dialog) — see
    // LyricRealignUIState.
    @State var lyricRealign = LyricRealignUIState()
    // Audio-attachment playback state (controller, cues, highlight override, active cue/attachment) —
    // see AudioPlaybackUIState.
    @State var audioPlayback = AudioPlaybackUIState()
    @AppStorage(LyricsHighlightGranularity.storageKey) var lyricsHighlightGranularityRaw = LyricsHighlightGranularity.defaultValue.rawValue

    // Typed view of the granularity AppStorage, falling back to the default when the persisted
    // raw value pre-dates a new case being added.
    var lyricsHighlightGranularity: LyricsHighlightGranularity {
        LyricsHighlightGranularity(rawValue: lyricsHighlightGranularityRaw) ?? LyricsHighlightGranularity.defaultValue
    }
    // LLM-correction UI state (in-flight request, pending per-location changes, alerts) — see
    // LLMCorrectionUIState.
    @State var llmCorrection = LLMCorrectionUIState()
    @AppStorage(LLMSettings.useLLMKey) private var llmUseLLM = false
    @AppStorage(LLMSettings.stubResponseKey) private var llmStubResponse = ""
    @AppStorage(SongBreakdownService.songStubResponseKey) private var breakdownStubResponse = ""
    // Keys themselves live in the Keychain; the revision counter is the reactive
    // signal that a key was added or cleared in Settings.
    @AppStorage(LLMSettings.keysRevisionKey) private var llmKeysRevision = 0
    @Environment(\.scenePhase) var scenePhase

    // Initializes the read screen with the active note selection and shared read resources.
    init(
        selectedNote: Binding<Note?>,
        shouldActivateEditModeOnLoad: Binding<Bool> = .constant(false),
        pendingScrollTarget: Binding<ReadNoteTarget?> = .constant(nil),
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
        onActiveNoteChanged: ((UUID) -> Void)? = nil,
        onFocusSetting: ((String) -> Void)? = nil
    ) {
        _selectedNote = selectedNote
        _shouldActivateEditModeOnLoad = shouldActivateEditModeOnLoad
        _pendingScrollTarget = pendingScrollTarget
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
        self.onFocusSetting = onFocusSetting
    }

    // false: tap opens the lightweight popover (star / speak / meaning / arrow) first; the arrow
    // escalates to the full sheet. true skips straight to the full sheet. User-facing toggle in
    // Settings → Dictionary ("Open Full Lookup on Tap").
    @AppStorage(DictionarySettings.prefersSheetDirectSegmentActionsKey) var prefersSheetDirectSegmentActions: Bool = DictionarySettings.defaultPrefersSheetDirectSegmentActions

    // Reactive equivalent of LLMSettings.isConfigured() — re-evaluates when any LLM
    // setting changes. Reading llmKeysRevision ties body invalidation to key edits;
    // the actual presence check goes to the Keychain. Internal so the toolbar and
    // title-row extensions can enable/disable their LLM buttons appropriately.
    // Apple Intelligence (on-device or Cloud/Cloud Pro) requires no key, so it counts as
    // configured whenever the corresponding model is present and ready, regardless of
    // remote key state.
    var isLLMConfigured: Bool {
        _ = llmKeysRevision
        if llmUseLLM {
            let provider = LLMSettings.activeProvider()
            if provider == .appleIntelligence {
                return AppleIntelligenceAvailability.isAvailable
            }
            if provider == .appleIntelligenceCloud || provider == .appleIntelligenceCloudPro {
                return AppleIntelligenceCloudAvailability.isAvailable
            }
            return LLMSettings.apiKey(for: provider) != nil
        } else {
            return llmStubResponse.isEmpty == false
        }
    }

    // Reactive equivalent of "is song breakdown usable with the active provider" — deliberately
    // NOT shared with isLLMConfigured above, because breakdown and correction support opposite
    // Apple Intelligence variants: correction is on-device-only (SongBreakdownError.appleIntelligenceUnsupported
    // when Apple Intelligence Cloud/Cloud Pro is picked there), while breakdown is Cloud/Cloud
    // Pro-only (SongBreakdownError.appleIntelligenceUnsupported when on-device is picked here).
    // Reusing isLLMConfigured for the title row's breakdown button would hide the ONLY feature a
    // Cloud-configured user actually has, even though LLMSettings.isConfigured() reports them
    // configured. Also reads the breakdown-specific stub key in stub mode, not correction's —
    // the two stubs are independent (see SongBreakdownService's own key comment).
    var isBreakdownConfigured: Bool {
        _ = llmKeysRevision
        if llmUseLLM {
            switch LLMSettings.activeProvider() {
            case .appleIntelligence:
                return false
            case .appleIntelligenceCloud, .appleIntelligenceCloudPro:
                return AppleIntelligenceCloudAvailability.isAvailable
            case .none, .openAI, .claude:
                return LLMSettings.activeAPIKey() != nil
            }
        } else {
            return breakdownStubResponse.isEmpty == false
        }
    }

    // The Note currently visible in Read, resolved against the canonical store. ReadView's
    // load handler consumes the `selectedNote` binding (clears it once `activeNoteID` is
    // populated), so anything that wants the displayed note has to look it up here. Used by
    // the breakdown sheet so it shows the right note regardless of how it got loaded
    // (selection from Notes, restored from `lastActiveNoteID`, fresh OCR import).
    var currentDisplayedNote: Note? {
        if let id = document.activeNoteID, let stored = notesStore.note(withID: id) {
            return stored
        }
        // Unsaved buffer fallback: a fresh note created via "New Note" hasn't been added
        // to the store yet. We still want the breakdown sheet to work against the typed
        // text — synthesize a transient Note carrying whatever's in the editor right now.
        if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return Note(id: document.activeNoteID ?? UUID(), content: document.text)
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
