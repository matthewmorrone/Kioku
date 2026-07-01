import SwiftUI

// Bundles all heavy read-tab resources into one @State so SwiftUI sees a single atomic change.
nonisolated private struct ReadResources {
    var segmenter: any TextSegmenting = Segmenter(trie: DictionaryTrie())
    var dictionaryStore: DictionaryStore?
    var lexicon: Lexicon?
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()
    var frequencyRankBySurface: FrequencyRankMap = FrequencyRankMap()
    // True once `surfaceReadingData` is populated — published in Stage 1, BEFORE the heavy trie/lexicon
    // build (`ready`). The lookup/split frequency readout only needs the reading map, so this lets it
    // resolve scores in ~1s instead of waiting for the full engine. Distinct from `ready`.
    var frequencyDataReady: Bool = false
    var ready: Bool = false
    var segmenterRevision: Int = 0
}

// Hosts top-level tab navigation and shared app state wiring.
struct ContentView: View {
    @State private var selectedTab: ContentTab
    @StateObject private var notesStore = NotesStore()
    @StateObject private var wordsStore = WordsStore()
    @StateObject private var savedKanjiStore = SavedKanjiStore()
    @StateObject private var wordListsStore = WordListsStore()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var songBreakdownStore = SongBreakdownStore()
    // Background queue that runs LLM correction on notes the bulk-import sheet
    // hands over. Attached to notesStore in onAppear for the same
    // @StateObject-can't-see-other-@StateObject reason as the bridge server.
    @StateObject private var llmCorrectionQueue = LLMCorrectionQueue()
    // Lifetime tied to the app shell so Settings can start/stop the listener freely; the
    // notes store is attached during onAppear because @StateObject initializers can't see
    // each other.
    @StateObject private var bridgeServer = KiokuBridgeServer()
    @State private var selectedReadNote: Note?
    @State private var shouldActivateReadEditMode = false
    @State private var readResources = ReadResources()
    @State private var hasLoadedReadResources = false
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""
    // Drives the live re-apply of nav/tab bar chrome when the user toggles the theme in Settings.
    @AppStorage(Theme.storageKey) private var japaneseTheme = false
    @AppStorage(SegmenterSettings.backendKey) private var segmenterBackendSetting = SegmenterSettings.defaultBackend
    @AppStorage(SegmenterSettings.mecabDictionaryKey) private var mecabDictionarySetting = SegmenterSettings.defaultMeCabDictionary
    @AppStorage(SegmenterSettings.strategyKey) private var segmentationStrategySetting: SegmentationStrategy = SegmenterSettings.defaultStrategy
    // Observes the same shared instance the AppDelegate registered the notification handler against,
    // so a deep-link target published from didReceive reaches this view.
    @ObservedObject private var wotdNavigation = WordOfTheDayNavigation.shared
    @StateObject private var clipboardCoordinator = ClipboardLookupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    // Set by notification and read-tab actions; consumed by WordsView.
    @State private var pendingWordsRoute: WordsRoute? = nil
    @State private var wotdRefreshTask: Task<Void, Never>?

    // Initializes the selected tab so previews and deep links can choose an initial section.
    init(selectedTab: ContentTab = .read) {
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Renders the Read tab screen and keeps last-active note tracking in sync.
            ReadView(
                selectedNote: $selectedReadNote,
                shouldActivateEditModeOnLoad: $shouldActivateReadEditMode,
                segmenter: readResources.segmenter,
                dictionaryStore: readResources.dictionaryStore,
                lexicon: readResources.lexicon,
                surfaceReadingData: readResources.surfaceReadingData,
                kanjiReadingFallback: readResources.kanjiReadingFallback,
                frequencyRankBySurface: readResources.frequencyRankBySurface,
                frequencyDataReady: readResources.frequencyDataReady,
                segmenterRevision: readResources.segmenterRevision,
                readResourcesReady: readResources.ready,
                onOpenWordDetail: handleOpenWordDetail,
                onActiveNoteChanged: handleActiveNoteChanged
            )
            .tag(ContentTab.read)
            .tabItem {
                Label("Read", systemImage: "book")
            }

            // Renders the Notes tab list and routes selected/new notes into the Read tab.
            // Callback bodies are extracted to named methods so the constructor stays
            // small — SwiftUI's type-checker times out when a single constructor accumulates
            // too many inline closures.
            NotesView(
                onSelectNote: handleNoteSelected,
                onCreateNote: handleNewNoteRequested,
                onUpdateSelectedNote: handleNoteUpdated,
                onOCRImportedNote: handleOCRImported
            )
            .tag(ContentTab.notes)
            .tabItem {
                Label("Notes", systemImage: "text.line.magnify")
            }

            // Renders the Words tab entry point; pendingWordsRoute carries notification and read-tab routes.
            WordsView(dictionaryStore: readResources.dictionaryStore, segmenter: readResources.segmenter, lexicon: readResources.lexicon, surfaceReadingData: readResources.surfaceReadingData, kanjiReadingFallback: readResources.kanjiReadingFallback, pendingRoute: $pendingWordsRoute)
                .environmentObject(wordsStore)
                .environmentObject(savedKanjiStore)
                .environmentObject(wordListsStore)
                .environmentObject(historyStore)
            .tag(ContentTab.words)
            .tabItem {
                Label("Words", systemImage: "text.page.badge.magnifyingglass")
            }

            // Renders the Learn tab entry point, passing the dictionary store for flashcard lookups.
            LearnView(dictionaryStore: readResources.dictionaryStore, segmenter: readResources.segmenter, surfaceReadingData: readResources.surfaceReadingData, kanjiReadingFallback: readResources.kanjiReadingFallback)
            .tag(ContentTab.learn)
            .tabItem {
                Label("Learn", systemImage: "rectangle.on.rectangle.angled")
            }

            // Renders the Settings tab entry point.
            SettingsView(dictionaryStore: readResources.dictionaryStore, bridgeServer: bridgeServer)
            .tag(ContentTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        // Floating LLM correction-queue progress card pinned above the tab bar so the
        // user can see batch progress from any tab and minimize it when not needed.
        // Auto-hides when there's no activity (no run in flight + no recent results).
        .overlay(alignment: .bottom) {
            CorrectionProgressOverlay()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .allowsHitTesting(true)
        }
        // Vermilion accent app-wide when the Japanese Theme is on (and the system accent when off).
        // On iOS 26 SwiftUI's TabView applies its own tint that overrides both the AccentColor asset
        // and UITabBar.appearance(), so the tint must be set explicitly here.
        .themedTint()
        // Re-apply or reset the nav/tab bar chrome the moment the toggle flips. Bars already on
        // screen refresh on the next navigation; the rest of the theme updates live.
        .onChange(of: japaneseTheme) { _, _ in Theme.refreshGlobalAppearance() }
        .environmentObject(notesStore)
        .environmentObject(wordsStore)
        .environmentObject(savedKanjiStore)
        .environmentObject(wordListsStore)
        .environmentObject(historyStore)
        .environmentObject(reviewStore)
        .environmentObject(songBreakdownStore)
        .environmentObject(llmCorrectionQueue)
        .environmentObject(wotdNavigation)
        .onAppear {
            StartupTimer.mark("onAppear fired")
            restoreLastActiveNote()
            loadReadResourcesIfNeeded()
            // Wires the live notes store into the bridge so any MCP-side mutations route
            // through the same single-writer store the UI binds against.
            bridgeServer.attach(notesStore: notesStore)
            // Same wiring for the LLM correction queue — it needs the store reference
            // to resolve note IDs and persist corrections after each run.
            llmCorrectionQueue.attach(store: notesStore)
        }
        // Navigate to Words tab and open the word detail when a notification deep link arrives.
        // The notification's surface is threaded into the route so WordsView.detailWord can resolve
        // the target even before the dictionary store loads or if the word left the saved set.
        .onChange(of: wotdNavigation.pendingTarget) { _, target in
            guard let target else { return }
            WOTDDiag.log("ContentView route entryID=\(target.entryID) hasSurface=\(target.surface != nil) -> Words tab")
            selectedTab = .words
            DispatchQueue.main.async {
                pendingWordsRoute = .detail(entryID: target.entryID, surface: target.surface)
            }
            wotdNavigation.pendingTarget = nil
        }
        // Rebuild the segmenter when the user switches backend or MeCab dictionary in Settings.
        .onChange(of: segmenterBackendSetting) { _, _ in
            rebuildReadResources()
        }
        .onChange(of: mecabDictionarySetting) { _, _ in
            rebuildReadResources()
        }
        // Bump the segmenter revision so ReadView re-segments existing text with the new strategy.
        .onChange(of: segmentationStrategySetting) { _, _ in
            rebuildReadResources()
        }
        // Validate WOTD scheduling after startup has settled rather than on the critical path.
        .onChange(of: readResources.ready) { _, ready in
            guard ready else { return }
            // Reconcile saved words against the live dictionary's ent_seq maps before anything reads
            // them — backfills the stable key on legacy cards and corrects any rebuild drift.
            if let store = readResources.dictionaryStore {
                wordsStore.enableStableKeyMigration(using: store)
            }
            scheduleWotdRefresh(reason: "startup validation", delayNanoseconds: 2_000_000_000, forceRefresh: false)
        }
        // Refresh WOTD when the underlying saved-word set changes.
        .onChange(of: wordsStore.words) { _, _ in
            guard readResources.ready else { return }
            scheduleWotdRefresh(reason: "words changed", delayNanoseconds: 500_000_000, forceRefresh: true)
        }
        // Probe the pasteboard whenever the app becomes active; reads only the change counter.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            clipboardCoordinator.checkClipboard()
        }
        .overlay(alignment: .bottom) {
            if clipboardCoordinator.hasPendingClipboard {
                ClipboardLookupBanner(
                    onLookup: handleClipboardLookup,
                    onDismiss: { clipboardCoordinator.dismiss() }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 56)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: clipboardCoordinator.hasPendingClipboard)
    }

    // Reads the pasteboard, switches to Words, and populates the search field with the clipboard content.
    private func handleClipboardLookup() {
        guard let content = clipboardCoordinator.consumeClipboard() else { return }
        selectedTab = .words
        DispatchQueue.main.async {
            pendingWordsRoute = .search(content)
        }
    }

    // MARK: - ReadView / NotesView callback handlers
    //
    // Extracted from inline closures so the TabView body keeps a flat, type-checkable shape.
    // SwiftUI's type inferencer chokes on view constructors that accumulate too many
    // closures (each one a fresh `(some View) -> some View` to resolve).

    // Open-word-detail callback from ReadView: switch to Words and push a detail route.
    private func handleOpenWordDetail(entryID: Int64, surface: String, reading: String?, sublatticePaths: [[String]]) {
        selectedTab = .words
        DispatchQueue.main.async {
            pendingWordsRoute = .detail(entryID: entryID, surface: surface, reading: reading, sublatticePaths: sublatticePaths)
        }
    }

    // Active-note-changed callback from ReadView: persist for restoreLastActiveNote.
    private func handleActiveNoteChanged(_ id: UUID) {
        lastActiveNoteID = id.uuidString
    }

    // User tapped a row in the Notes list — select it in Read and jump there.
    private func handleNoteSelected(_ note: Note) {
        selectedReadNote = note
        lastActiveNoteID = note.id.uuidString
        selectedTab = .read
    }

    // User tapped New Note in Notes — hand Read a fresh unsaved Note (Read persists once
    // content is typed) and jump there in edit mode.
    private func handleNewNoteRequested() {
        let newNote = Note()
        shouldActivateReadEditMode = true
        selectedReadNote = newNote
        lastActiveNoteID = newNote.id.uuidString
        selectedTab = .read
    }

    // Notes-store changes streamed up so the in-memory selectedReadNote stays in sync
    // with on-disk edits / deletes initiated from the Notes tab.
    private func handleNoteUpdated(_ updatedNote: Note?) {
        if let currentSelectedReadNote = selectedReadNote, let updatedNote, updatedNote.id == currentSelectedReadNote.id {
            selectedReadNote = updatedNote
            lastActiveNoteID = updatedNote.id.uuidString
            return
        }
        if let updatedNote, let activeNoteID = UUID(uuidString: lastActiveNoteID), updatedNote.id == activeNoteID {
            selectedReadNote = updatedNote
            return
        }
        if updatedNote == nil {
            if let currentSelectedReadNote = selectedReadNote, notesStore.note(withID: currentSelectedReadNote.id) == nil {
                selectedReadNote = nil
                lastActiveNoteID = ""
            } else if let activeNoteID = UUID(uuidString: lastActiveNoteID), notesStore.note(withID: activeNoteID) == nil {
                lastActiveNoteID = ""
            }
        }
    }

    // OCR finished on Notes — install the recognized Note in the store, make it the
    // active Read note, jump tabs, and arm edit mode so the user lands directly in the
    // editor (mirrors the previous Read-side OCR end state).
    private func handleOCRImported(_ recognizedNote: Note) {
        notesStore.addNote(recognizedNote)
        shouldActivateReadEditMode = true
        selectedReadNote = recognizedNote
        lastActiveNoteID = recognizedNote.id.uuidString
        selectedTab = .read
    }

    // Restores the previously active note so users return to their last reading context.
    private func restoreLastActiveNote() {
        guard let noteID = UUID(uuidString: lastActiveNoteID) else { return }

        StartupTimer.measure("restoreLastActiveNote.reload") {
            notesStore.reload()
        }
        guard let note = notesStore.notes.first(where: { $0.id == noteID }) else { return }

        StartupTimer.mark("restoreLastActiveNote selected note")
        selectedReadNote = note
        selectedTab = .read
    }

    // Loads heavy read resources asynchronously so initial app launch stays responsive.
    private func loadReadResourcesIfNeeded() {
        guard !hasLoadedReadResources else { return }
        hasLoadedReadResources = true
        rebuildReadResources()
    }

    // Schedules a deferred WOTD refresh so startup can stay responsive while still validating stale schedules.
    private func scheduleWotdRefresh(reason: String, delayNanoseconds: UInt64, forceRefresh: Bool) {
        wotdRefreshTask?.cancel()
        let words = wordsStore.words
        let store = readResources.dictionaryStore
        let enabled = UserDefaults.standard.bool(forKey: WordOfTheDayScheduler.enabledKey)
        let hour = UserDefaults.standard.object(forKey: WordOfTheDayScheduler.hourKey) != nil
            ? UserDefaults.standard.integer(forKey: WordOfTheDayScheduler.hourKey)
            : 9
        let minute = UserDefaults.standard.integer(forKey: WordOfTheDayScheduler.minuteKey)

        wotdRefreshTask = Task.detached(priority: .utility) {
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }

            guard Task.isCancelled == false else { return }
            await WordOfTheDayScheduler.refreshScheduleIfEnabled(
                words: words,
                dictionaryStore: store,
                hour: hour,
                minute: minute,
                enabled: enabled,
                forceRefresh: forceRefresh
            )
        }
    }

    // Rebuilds the segmenter and related resources on a background thread using the current settings.
    //
    // Two-stage publish: the bare DictionaryStore lands on the main actor as soon as SQLite
    // opens (sub-second), so the Words tab's search bar becomes live immediately. The full
    // segmenter + lexicon + prewarmed maps (POS bits, canonical entry ids, surface readings)
    // follow afterwards on a slower path and overwrite the partial state once ready.
    private func rebuildReadResources() {
        let backend = UserDefaults.standard.string(forKey: SegmenterSettings.backendKey) ?? SegmenterSettings.defaultBackend
        let mecabDict = UserDefaults.standard.string(forKey: SegmenterSettings.mecabDictionaryKey) ?? SegmenterSettings.defaultMeCabDictionary

        let currentRevision = readResources.segmenterRevision
        Task.detached(priority: .userInitiated) {
            // Stage 1 — fast path: open the read-only SQLite handle so the dictionary search bar is
            // usable, AND build the surface-reading/frequency map (a ~0.3s scan) so the lookup/split
            // frequency readout can resolve scores now, instead of waiting for the slow trie+lexicon.
            let earlyStore = try? DictionaryStore()
            var earlyReadingData: [String: SurfaceReadingData]? = nil
            if let earlyStore {
                earlyReadingData = try? StartupTimer.measure("fetchSurfaceReadingData (early)") {
                    try earlyStore.fetchSurfaceReadingData()
                }
                let publishedReadingData = earlyReadingData
                await MainActor.run {
                    if readResources.dictionaryStore == nil {
                        readResources.dictionaryStore = earlyStore
                        StartupTimer.mark("dictionaryStore published (fast path)")
                    }
                    if let publishedReadingData {
                        readResources.surfaceReadingData = SurfaceReadingDataMap(publishedReadingData)
                        readResources.frequencyDataReady = true
                        StartupTimer.mark("surfaceReadingData published (early)")
                    }
                }
            }

            // Stage 2 — slow path: full segmenter/lexicon build + DictionaryStore prewarming. Reuses
            // the reading map already built above so it isn't scanned a second time.
            let result = Self.makeReadResources(backend: backend, mecabDictionary: mecabDict, prebuiltSurfaceReadingData: earlyReadingData)
            await MainActor.run {
                readResources = ReadResources(
                    segmenter: result.segmenter,
                    dictionaryStore: result.dictionaryStore,
                    lexicon: result.lexicon,
                    surfaceReadingData: result.surfaceReadingData,
                    kanjiReadingFallback: result.kanjiReadingFallback,
                    frequencyRankBySurface: result.frequencyRankBySurface,
                    frequencyDataReady: true,
                    ready: true,
                    segmenterRevision: currentRevision + 1
                )
                StartupTimer.mark("readResourcesReady published to UI")
            }
        }
    }

    // Builds the read-tab segmenter and dictionary store used for furigana lookup.
    // Uses the specified backend and MeCab dictionary when MeCab is selected.
    private nonisolated static func makeReadResources(backend: String, mecabDictionary: String, prebuiltSurfaceReadingData: [String: SurfaceReadingData]? = nil) -> (segmenter: any TextSegmenting, dictionaryStore: DictionaryStore?, lexicon: Lexicon?, surfaceReadingData: SurfaceReadingDataMap, kanjiReadingFallback: KanjiReadingFallbackMap, frequencyRankBySurface: FrequencyRankMap) {
        StartupTimer.mark("makeReadResources started")
        let overallStart = CFAbsoluteTimeGetCurrent()

        let trie = DictionaryTrie()
        var dictionaryStore: DictionaryStore?
        var lexicon: Lexicon?
        var surfaceReadingData: [String: SurfaceReadingData] = [:]
        var kanjiReadingFallback: [Character: String] = [:]
        var deinflector: Deinflector?
        // Per-entry POS bits, captured from the same surface-data scan that builds the trie.
        // Threaded into the trie-Viterbi Segmenter so its lemma-candidate POS gate can tell a
        // verb (する) from a noun — without it the gate sees all-zero bits and drops every
        // deinflected verb candidate (e.g. した → する).
        var partOfSpeechByEntryID: [Int: UInt64] = [:]

        do {
            let store = try StartupTimer.measure("DictionaryStore.init") {
                try DictionaryStore()
            }
            dictionaryStore = store

            // Populate the surface → canonical entry id map before publishing so all later
            // saved-word identity lookups (Add All, prewarm, CSV import) become hashtable
            // hits instead of per-surface SQL — eliminates the fallback storm that used to
            // dominate Add All latency.
            do { try StartupTimer.measure("populateCanonicalEntryIDMap") {
                try store.populateCanonicalEntryIDMap()
            }} catch { print("populateCanonicalEntryIDMap failed: \(error)") }

            // ent_seq ⇄ row-id maps, so saved words keyed by the stable JMdict ent_seq can resolve
            // to the current (rebuild-unstable) row id.
            do { try StartupTimer.measure("populateEntSeqMaps") {
                try store.populateEntSeqMaps()
            }} catch { print("populateEntSeqMaps failed: \(error)") }

            // Surface → POS bits map. Used by Lexicon's deinflection pruning to gate
            // candidates without per-call SQL — the old hot path hit `posBits(for:)`
            // hundreds of times during a single tap because every BFS-generated
            // deinflection candidate needed an entry lookup just to check POS.
            do { try StartupTimer.measure("populateSurfacePOSBitsMap") {
                try store.populateSurfacePOSBitsMap()
            }} catch { print("populateSurfacePOSBitsMap failed: \(error)") }

            // entry_id → JLPT level map. Backs the Words JLPT filter and the Flashcards/Multiple
            // Choice level pickers with O(1) per-saved-word lookups instead of SQL. Empty (and
            // harmless) on a dictionary built before the entry_jlpt_level migration.
            do { try StartupTimer.measure("populateJLPTLevelMap") {
                try store.populateJLPTLevelMap()
            }} catch { print("populateJLPTLevelMap failed: \(error)") }

            // Reuse the map already built on the Stage 1 fast path when available, so the heavy
            // surface-reading scan isn't run twice.
            if let prebuiltSurfaceReadingData {
                surfaceReadingData = prebuiltSurfaceReadingData
            } else {
                do { surfaceReadingData = try StartupTimer.measure("fetchSurfaceReadingData") {
                    try store.fetchSurfaceReadingData()
                }} catch { print("fetchSurfaceReadingData failed: \(error)") }
            }

            // Last-resort per-kanji furigana source. Loaded alongside the word-level map so any
            // kanji without a dictionary word/lemma reading still gets *some* ruby (see
            // KanjiReadingFallbackMap). Cheap relative to the 327k-entry surface map (~13k kanji).
            do { kanjiReadingFallback = try StartupTimer.measure("fetchKanjiReadingFallbackMap") {
                try store.fetchKanjiReadingFallbackMap()
            }} catch { print("fetchKanjiReadingFallbackMap failed: \(error)") }

            do {
                // SurfaceRecords carry POS bits + IPADic context IDs so Viterbi can look up
                // bigram costs directly in matrix.bin. The fetch path was rewritten to aggregate
                // POS per entry in a first pass (small) and join in-memory against surface rows
                // in a second pass — avoids the JOIN-explosion that OOM-killed the app earlier.
                let surfaceData = try StartupTimer.measure("fetchSurfaceData") {
                    try store.fetchSurfaceData()
                }
                partOfSpeechByEntryID = surfaceData.partOfSpeechByEntryID
                StartupTimer.measure("trie population (\(surfaceData.surfaceRecords.count) records)") {
                    for record in surfaceData.surfaceRecords { trie.insert(record) }
                }
            } catch { print("fetchSurfaceData failed: \(error)") }

        } catch {
            print("DictionaryStore initialization failed: \(error)")
        }

        do {
            deinflector = try StartupTimer.measure("Deinflector.init") {
                try Deinflector(
                    trie: trie,
                    bundle: .main,
                    resourceName: "deinflection",
                    fileExtension: "json"
                )
            }
        } catch {
            print("Deinflector initialization failed: \(error)")
        }

        // Frequency comes straight from word_frequency (the table that carries jpdb_rank), NOT from
        // surface_readings.jpdb_rank — that column is NULL for kana surfaces, so reading it produced
        // an empty map and left the segmenter's frequency term inert. fetchBestRankBySurface reads the
        // populated source with per-entry rank propagation. The segmenter consumes the derived SCORE
        // map; the lookup/split-editor frequency fallback consumes the RANK map directly (so a kana
        // split piece like こと / する reports its entry's rank instead of rendering a bare "–").
        let frequencyRankBySurface: [String: Int] = StartupTimer.measure("frequencyRankBySurface build") {
            (try? dictionaryStore?.fetchBestRankBySurface()) ?? [:]
        }
        let frequencyScoreBySurface: [String: Double] = frequencyRankBySurface.reduce(into: [:]) { result, pair in
            if let score = FrequencyData(jpdbRank: pair.value, wordfreqZipf: nil).normalizedScore, score > 0 {
                result[pair.key] = score
            }
        }

        // Choose segmenter based on the user's backend preference.
        let segmenter: any TextSegmenting = StartupTimer.measure("Segmenter.init (backend: \(backend))") {
            if backend == SegmenterBackend.mecab.rawValue,
               let dict = MeCabDictionary(rawValue: mecabDictionary),
               let mecabSegmenter = MeCabSegmenter(dictionary: dict) {
                return mecabSegmenter
            } else if backend == SegmenterBackend.nlTokenizer.rawValue {
                return NLTokenizerSegmenter()
            } else {
                return Segmenter(trie: trie, deinflector: deinflector, partOfSpeechByEntryID: partOfSpeechByEntryID, frequencyScoreBySurface: frequencyScoreBySurface)
            }
        }

        if let deinflector {
            lexicon = StartupTimer.measure("Lexicon.init") {
                Lexicon(
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    deinflector: deinflector,
                    surfaceReadingData: surfaceReadingData
                )
            }
        } else {
            print("Lexicon data surface initialization failed: missing deinflector")
        }

        let overallElapsed = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
        StartupTimer.mark("makeReadResources total: \(String(format: "%.1f", overallElapsed)) ms")

        return (
            segmenter: segmenter,
            dictionaryStore: dictionaryStore,
            lexicon: lexicon,
            surfaceReadingData: SurfaceReadingDataMap(surfaceReadingData),
            kanjiReadingFallback: KanjiReadingFallbackMap(kanjiReadingFallback),
            frequencyRankBySurface: FrequencyRankMap(frequencyRankBySurface)
        )
    }
}

#Preview {
    ContentView()
}
