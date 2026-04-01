import SwiftUI

// Bundles all heavy read-tab resources into one @State so SwiftUI sees a single atomic change.
private struct ReadResources {
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
    @State private var selectedReadNote: Note?
    @State private var shouldActivateReadEditMode = false
    @State private var readResources = ReadResources()
    @State private var hasLoadedReadResources = false
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""
    @AppStorage(SegmenterSettings.backendKey) private var segmenterBackendSetting = SegmenterSettings.defaultBackend
    @AppStorage(SegmenterSettings.mecabDictionaryKey) private var mecabDictionarySetting = SegmenterSettings.defaultMeCabDictionary
    @StateObject private var wotdNavigation = WordOfTheDayNavigation()
    // Retained for its delegate lifetime; nil until onAppear.
    @State private var notificationHandler: NotificationDeepLinkHandler?
    // Set by WordOfTheDayNavigation observer; consumed by WordsView to open a word detail.
    @State private var pendingDeepLinkEntryID: Int64? = nil

    // Initializes the selected tab so previews and deep links can choose an initial section.
    init(selectedTab: ContentTab = .read) {
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Renders the Read tab screen and keeps last-active note tracking in sync.
            ReadView(selectedNote: $selectedReadNote, shouldActivateEditModeOnLoad: $shouldActivateReadEditMode, segmenter: readResources.segmenter, dictionaryStore: readResources.dictionaryStore, lexicon: readResources.lexicon, surfaceReadingData: readResources.surfaceReadingData, segmenterRevision: readResources.segmenterRevision, readResourcesReady: readResources.ready, onActiveNoteChanged: { id in
                lastActiveNoteID = id.uuidString
            })
            .tag(ContentTab.read)
            .tabItem {
                Label("Read", systemImage: "book")
            }

            // Renders the Notes tab list and routes selected/new notes into the Read tab.
            NotesView(onSelectNote: { note in
                selectedReadNote = note
                lastActiveNoteID = note.id.uuidString
                selectedTab = .read
            }, onCreateNote: {
                // Pass a fresh note directly without adding it to the store so that the note
                // is only persisted once the user types content into the editor.
                let newNote = Note()
                shouldActivateReadEditMode = true
                selectedReadNote = newNote
                lastActiveNoteID = newNote.id.uuidString
                selectedTab = .read
            }, onUpdateSelectedNote: { updatedNote in
                if let currentSelectedReadNote = selectedReadNote, let updatedNote, updatedNote.id == currentSelectedReadNote.id {
                    selectedReadNote = updatedNote
                    lastActiveNoteID = updatedNote.id.uuidString
                    return
                }

                // When the updated note is the currently active note in the read view (selectedReadNote
                // is nil after initial load), re-set it to trigger a reload so in-memory state stays in sync.
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
            })
            .tag(ContentTab.notes)
            .tabItem {
                Label("Notes", systemImage: "text.line.magnify")
            }

            // Renders the Words tab entry point; deepLinkedEntryID carries notification deep links.
            WordsView(dictionaryStore: readResources.dictionaryStore, deepLinkedEntryID: $pendingDeepLinkEntryID)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .environmentObject(historyStore)
            .tag(ContentTab.words)
            .tabItem {
                Label("Words", systemImage: "text.page.badge.magnifyingglass")
            }

            // Renders the Learn tab entry point, passing the dictionary store for flashcard lookups.
            LearnView(dictionaryStore: readResources.dictionaryStore)
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
                pendingDeepLinkEntryID = entryID
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
        // Refresh the Word of the Day schedule once dictionary resources are ready.
        .onChange(of: readResources.ready) { _, ready in
            guard ready else { return }
            let words = wordsStore.words
            let store = readResources.dictionaryStore
            let enabled = UserDefaults.standard.bool(forKey: WordOfTheDayScheduler.enabledKey)
            // Fall back to 9am when the key has never been written (object returns nil for missing keys).
            let hour = UserDefaults.standard.object(forKey: WordOfTheDayScheduler.hourKey) != nil
                ? UserDefaults.standard.integer(forKey: WordOfTheDayScheduler.hourKey)
                : 9
            let minute = UserDefaults.standard.integer(forKey: WordOfTheDayScheduler.minuteKey)
            Task.detached(priority: .utility) {
                await WordOfTheDayScheduler.refreshScheduleIfEnabled(
                    words: words,
                    dictionaryStore: store,
                    hour: hour,
                    minute: minute,
                    enabled: enabled
                )
            }
        }
    }

    // Restores the previously active note so users return to their last reading context.
    private func restoreLastActiveNote() {
        guard let noteID = UUID(uuidString: lastActiveNoteID) else { return }

        notesStore.reload()
        guard let note = notesStore.notes.first(where: { $0.id == noteID }) else { return }

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
    private static func makeReadResources(backend: String, mecabDictionary: String) -> (segmenter: any TextSegmenting, dictionaryStore: DictionaryStore?, lexicon: Lexicon?, surfaceReadingData: SurfaceReadingDataMap) {
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

            do { surfaceReadingData = try StartupTimer.measure("fetchSurfaceReadingData") {
                try store.fetchSurfaceReadingData()
            }} catch { print("fetchSurfaceReadingData failed: \(error)") }

            do {
                let surfaces = try StartupTimer.measure("fetchAllSurfaces") {
                    try store.fetchAllSurfaces()
                }
                StartupTimer.measure("trie population (\(surfaces.count) surfaces)") {
                    for surface in surfaces { trie.insert(surface) }
                }
            } catch { print("fetchAllSurfaces failed: \(error)") }

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

        // Choose segmenter based on the user's backend preference.
        let segmenter: any TextSegmenting = StartupTimer.measure("Segmenter.init (backend: \(backend))") {
            if backend == SegmenterBackend.mecab.rawValue,
               let dict = MeCabDictionary(rawValue: mecabDictionary),
               let mecabSegmenter = MeCabSegmenter(dictionary: dict) {
                return mecabSegmenter
            } else if backend == SegmenterBackend.nlTokenizer.rawValue {
                return NLTokenizerSegmenter()
            } else {
                return Segmenter(trie: trie, deinflector: deinflector)
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
