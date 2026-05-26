import SwiftUI

// Bundles all heavy read-tab resources into one @State so SwiftUI sees a single atomic change.
nonisolated private struct ReadResources {
    var segmenter: any TextSegmenting = Segmenter(trie: DictionaryTrie())
    var dictionaryStore: DictionaryStore?
    var lexicon: Lexicon?
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var ready: Bool = false
    var segmenterRevision: Int = 0
}

// Hosts top-level tab navigation and shared app state wiring.
struct ContentView: View {
    @State private var selectedTab: ContentTab
    @StateObject private var notesStore = NotesStore()
    @StateObject private var wordsStore = WordsStore()
    @StateObject private var wordListsStore = WordListsStore()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var songBreakdownStore = SongBreakdownStore()
    @State private var selectedReadNote: Note?
    @State private var shouldActivateReadEditMode = false
    @State private var readResources = ReadResources()
    @State private var hasLoadedReadResources = false
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""
    @AppStorage(SegmenterSettings.backendKey) private var segmenterBackendSetting = SegmenterSettings.defaultBackend
    @AppStorage(SegmenterSettings.mecabDictionaryKey) private var mecabDictionarySetting = SegmenterSettings.defaultMeCabDictionary
    @AppStorage(SegmenterSettings.viterbiEnabledKey) private var viterbiEnabledSetting = SegmenterSettings.defaultViterbiEnabled
    @StateObject private var wotdNavigation = WordOfTheDayNavigation()
    @StateObject private var clipboardCoordinator = ClipboardLookupCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    // Retained for its delegate lifetime; nil until onAppear.
    @State private var notificationHandler: NotificationDeepLinkHandler?
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
            WordsView(dictionaryStore: readResources.dictionaryStore, segmenter: readResources.segmenter, pendingRoute: $pendingWordsRoute)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .environmentObject(historyStore)
            .tag(ContentTab.words)
            .tabItem {
                Label("Words", systemImage: "text.page.badge.magnifyingglass")
            }

            // Renders the Learn tab entry point, passing the dictionary store for flashcard lookups.
            LearnView(dictionaryStore: readResources.dictionaryStore, segmenter: readResources.segmenter)
            .tag(ContentTab.learn)
            .tabItem {
                Label("Learn", systemImage: "rectangle.on.rectangle.angled")
            }

            // Renders the Settings tab entry point.
            SettingsView(dictionaryStore: readResources.dictionaryStore)
            .tag(ContentTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .environmentObject(notesStore)
        .environmentObject(wordsStore)
        .environmentObject(wordListsStore)
        .environmentObject(historyStore)
        .environmentObject(reviewStore)
        .environmentObject(songBreakdownStore)
        .environmentObject(wotdNavigation)
        .onAppear {
            StartupTimer.mark("onAppear fired")
            restoreLastActiveNote()
            loadReadResourcesIfNeeded()
            setupNotificationHandlerIfNeeded()
        }
        // Navigate to Words tab and open the word detail when a notification deep link arrives.
        .onChange(of: wotdNavigation.pendingEntryID) { _, entryID in
            guard let entryID else { return }
            selectedTab = .words
            DispatchQueue.main.async {
                pendingWordsRoute = .detail(entryID: entryID, surface: nil)
            }
            wotdNavigation.pendingEntryID = nil
        }
        // Rebuild the segmenter when the user switches backend or MeCab dictionary in Settings.
        .onChange(of: segmenterBackendSetting) { _, _ in
            rebuildReadResources()
        }
        .onChange(of: mecabDictionarySetting) { _, _ in
            rebuildReadResources()
        }
        // Bump the segmenter revision so ReadView re-segments existing text with the new scoring path.
        .onChange(of: viterbiEnabledSetting) { _, _ in
            rebuildReadResources()
        }
        // Validate WOTD scheduling after startup has settled rather than on the critical path.
        .onChange(of: readResources.ready) { _, ready in
            guard ready else { return }
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

    // Creates the notification handler once; subsequent onAppear calls are no-ops.
    private func setupNotificationHandlerIfNeeded() {
        guard notificationHandler == nil else { return }
        notificationHandler = NotificationDeepLinkHandler(navigation: wotdNavigation)
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
    private func rebuildReadResources() {
        let backend = UserDefaults.standard.string(forKey: SegmenterSettings.backendKey) ?? SegmenterSettings.defaultBackend
        let mecabDict = UserDefaults.standard.string(forKey: SegmenterSettings.mecabDictionaryKey) ?? SegmenterSettings.defaultMeCabDictionary

        // Task.detached runs the heavy dictionary/trie work off the main thread.
        // A single ReadResources assignment triggers one SwiftUI body re-eval instead of six.
        let currentRevision = readResources.segmenterRevision
        Task.detached(priority: .utility) {
            let result = Self.makeReadResources(backend: backend, mecabDictionary: mecabDict)
            await MainActor.run {
                readResources = ReadResources(
                    segmenter: result.segmenter,
                    dictionaryStore: result.dictionaryStore,
                    lexicon: result.lexicon,
                    surfaceReadingData: result.surfaceReadingData,
                    ready: true,
                    segmenterRevision: currentRevision + 1
                )
                StartupTimer.mark("readResourcesReady published to UI")
            }
        }
    }

    // Builds the read-tab segmenter and dictionary store used for furigana lookup.
    // Uses the specified backend and MeCab dictionary when MeCab is selected.
    private nonisolated static func makeReadResources(backend: String, mecabDictionary: String) -> (segmenter: any TextSegmenting, dictionaryStore: DictionaryStore?, lexicon: Lexicon?, surfaceReadingData: SurfaceReadingDataMap) {
        StartupTimer.mark("makeReadResources started")
        let overallStart = CFAbsoluteTimeGetCurrent()

        let trie = DictionaryTrie()
        var dictionaryStore: DictionaryStore?
        var lexicon: Lexicon?
        var surfaceReadingData: [String: SurfaceReadingData] = [:]
        var deinflector: Deinflector?

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

            // Surface → POS bits map. Used by Lexicon's deinflection pruning to gate
            // candidates without per-call SQL — the old hot path hit `posBits(for:)`
            // hundreds of times during a single tap because every BFS-generated
            // deinflection candidate needed an entry lookup just to check POS.
            do { try StartupTimer.measure("populateSurfacePOSBitsMap") {
                try store.populateSurfacePOSBitsMap()
            }} catch { print("populateSurfacePOSBitsMap failed: \(error)") }

            do { surfaceReadingData = try StartupTimer.measure("fetchSurfaceReadingData") {
                try store.fetchSurfaceReadingData()
            }} catch { print("fetchSurfaceReadingData failed: \(error)") }

            do {
                // SurfaceRecords carry POS bits + IPADic context IDs so Viterbi can look up
                // bigram costs directly in matrix.bin. The fetch path was rewritten to aggregate
                // POS per entry in a first pass (small) and join in-memory against surface rows
                // in a second pass — avoids the JOIN-explosion that OOM-killed the app earlier.
                let records = try StartupTimer.measure("fetchSurfaceRecords") {
                    try store.fetchSurfaceRecords()
                }
                StartupTimer.measure("trie population (\(records.count) records)") {
                    for record in records { trie.insert(record) }
                }
            } catch { print("fetchSurfaceRecords failed: \(error)") }

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

        // Derives the lemma → best-Zipf map from the surface-reading data so
        // Segmenter.preferredLemmaScore can break script-tied lemma choices
        // by real-world frequency. We pick the max Zipf across a lemma's
        // readings — for verbs with multiple kana forms, the highest-Zipf
        // reading is the strongest "this is the common word" signal.
        let wordfreqZipfByLemma: [String: Double] = StartupTimer.measure("wordfreqZipfByLemma build") {
            var map: [String: Double] = [:]
            map.reserveCapacity(surfaceReadingData.count)
            for (surface, data) in surfaceReadingData {
                var best: Double = 0
                for case let zipf? in data.frequencyByReading.values.map(\.wordfreqZipf) where zipf > best {
                    best = zipf
                }
                if best > 0 { map[surface] = best }
            }
            return map
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
                return Segmenter(trie: trie, deinflector: deinflector, wordfreqZipfByLemma: wordfreqZipfByLemma)
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
            surfaceReadingData: SurfaceReadingDataMap(surfaceReadingData)
        )
    }
}

#Preview {
    ContentView()
}
