import SwiftUI

// Bundles all heavy read-tab resources into one @State so SwiftUI sees a single atomic change.
nonisolated private struct ReadResources {
    var segmenter: any TextSegmenting = Segmenter(trie: DictionaryTrie())
    var dictionaryStore: DictionaryStore?
    var lexicon: Lexicon?
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()
    var frequencyRankBySurface: FrequencyRankMap = FrequencyRankMap()
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
    @StateObject private var songBreakdownStore = SongBreakdownStore()
    @StateObject private var customWordStore = CustomWordStore()
    @State private var selectedReadNote: Note?
    @State private var shouldActivateReadEditMode = false
    @State private var readResources = ReadResources()
    @State private var hasLoadedReadResources = false
    // The Custom Words the latest rebuild wrote into the dictionary. onAppear syncs the built-ins
    // just before the first rebuild, and the change that sync makes must not start a second one.
    @State private var customWordsInLatestRebuild: [CustomWord]?
    @State private var dictionaryDownloadManager = DictionaryDownloadManager()
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""
    // Drives the live re-apply of nav/tab bar chrome when the user toggles the theme in Settings.
    @AppStorage(Theme.storageKey) private var japaneseTheme = false
    @AppStorage(SegmenterSettings.strategyKey)
    private var segmentationStrategySetting: SegmentationStrategy = SegmenterSettings.defaultStrategy
    // Observes the same shared instance the AppDelegate registered the notification handler against,
    // so a deep-link target published from didReceive reaches this view.
    @ObservedObject private var wotdNavigation = WordOfTheDayNavigation.shared
    @ObservedObject private var readNoteNavigation = ReadNoteNavigation.shared
    // Set when readNoteNavigation resolves a note-open; ReadView consumes it once the target note
    // is actually active (activeNoteID == target.noteID) to scroll/select the first occurrence of
    // the surface. Carries the noteID too (not just the surface) so ReadView can tell this target
    // apart from stale text still on screen from whichever note was active before the switch.
    @State private var pendingReadScrollTarget: ReadNoteTarget?
    // Audio file picked by the Notes tab's Import Audio, handed to ReadView to transcribe.
    @State private var pendingReadAudioImportURL: URL?
    // Note that ReadView should start playing (lyrics view open) once it's the active note — set
    // by the "Sing with Kioku" Siri action, cleared by ReadView when consumed.
    @State private var pendingReadAutoplayNoteID: UUID?
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
                pendingScrollTarget: $pendingReadScrollTarget,
                pendingAudioImportURL: $pendingReadAudioImportURL,
                pendingAutoplayNoteID: $pendingReadAutoplayNoteID,
                segmenter: readResources.segmenter,
                dictionaryStore: readResources.dictionaryStore,
                lexicon: readResources.lexicon,
                surfaceReadingData: readResources.surfaceReadingData,
                kanjiReadingFallback: readResources.kanjiReadingFallback,
                frequencyRankBySurface: readResources.frequencyRankBySurface,
                segmenterRevision: readResources.segmenterRevision,
                readResourcesReady: readResources.ready,
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
                onOCRImportedNote: handleOCRImported,
                onAudioImported: handleAudioImported
            )
            .tag(ContentTab.notes)
            .tabItem {
                Label("Notes", systemImage: "text.line.magnify")
            }

            // Renders the Words tab entry point; pendingWordsRoute carries notification and read-tab routes.
            WordsView(
                dictionaryStore: readResources.dictionaryStore,
                segmenter: readResources.segmenter,
                lexicon: readResources.lexicon,
                surfaceReadingData: readResources.surfaceReadingData,
                kanjiReadingFallback: readResources.kanjiReadingFallback,
                pendingRoute: $pendingWordsRoute
            )
                .environmentObject(wordsStore)
                .environmentObject(savedKanjiStore)
                .environmentObject(wordListsStore)
                .environmentObject(historyStore)
            .tag(ContentTab.words)
            .tabItem {
                Label("Words", systemImage: "text.page.badge.magnifyingglass")
            }

            // Renders the Learn tab entry point, passing the dictionary store for flashcard lookups.
            LearnView(
                dictionaryStore: readResources.dictionaryStore,
                segmenter: readResources.segmenter,
                lexicon: readResources.lexicon,
                surfaceReadingData: readResources.surfaceReadingData,
                kanjiReadingFallback: readResources.kanjiReadingFallback
            )
            .tag(ContentTab.learn)
            .tabItem {
                Label("Learn", systemImage: "rectangle.on.rectangle.angled")
            }

            // Renders the Settings tab entry point.
            SettingsView(dictionaryStore: readResources.dictionaryStore, lexicon: readResources.lexicon)
            .tag(ContentTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        // Vermilion accent app-wide when the Japanese Theme is on (and the system accent when off).
        // On iOS 26 SwiftUI's TabView applies its own tint that overrides both the AccentColor asset
        // and UITabBar.appearance(), so the tint must be set explicitly here.
        .themedTint()
        // First-visit tours sit above every tab (and the tab bar) so the dimming covers the whole
        // window; each tab's tour starts the first time that tab is shown.
        .overlay { TourOverlay() }
        .onChange(of: selectedTab) { _, tab in
            TourCoordinator.shared.cancelPendingStart()
            TourCoordinator.shared.startIfUnseen(tab)
        }
        // Re-apply or reset the nav/tab bar chrome the moment the toggle flips. Bars already on
        // screen refresh on the next navigation; the rest of the theme updates live.
        .onChange(of: japaneseTheme) { _, _ in Theme.refreshGlobalAppearance() }
        .environmentObject(notesStore)
        .environmentObject(wordsStore)
        .environmentObject(savedKanjiStore)
        .environmentObject(wordListsStore)
        .environmentObject(historyStore)
        .environmentObject(songBreakdownStore)
        .environmentObject(customWordStore)
        .environmentObject(wotdNavigation)
        .environmentObject(readNoteNavigation)
        .onAppear {
            StartupTimer.mark("onAppear fired")
            // The built-in Custom Words this build ships; new ones join the list before it is applied.
            customWordStore.syncBuiltIns(CustomWordStore.bundledDefaults())
            if let firstSample = SampleNote.seedIfNeeded(into: notesStore).first {
                lastActiveNoteID = firstSample.id.uuidString
            }
            restoreLastActiveNote()
            syncSpotlight()
            TourCoordinator.shared.startIfUnseen(selectedTab)
            // A Siri launch can raise the request before this view exists to observe the change.
            playRandomAudioNoteIfRequested()
            loadReadResourcesIfNeeded()
            // dictionary.sqlite isn't bundled — download it if this is a fresh install, then
            // rebuild the read resources so DictionaryStore() (which failed silently above,
            // since nothing was downloaded yet) succeeds on this second attempt.
            Task { await downloadDictionaryAndRebuildIfNeeded() }
        }
        // Navigate to Words tab and open the word detail when a notification deep link arrives.
        // The notification's surface is threaded into the route so WordsView.detailWord can resolve
        // the target even before the dictionary store loads or if the word left the saved set.
        .onChange(of: wotdNavigation.pendingTarget) { _, target in
            guard let target else { return }
            WOTDDiag.log("ContentView route entryID=\(target.entryID) hasSurface=\(target.surface != nil) -> Words tab")
            routeToWords(.detail(entryID: target.entryID, surface: target.surface))
            wotdNavigation.pendingTarget = nil
        }
        // Tapping a source-note name in Word Detail's "Saved" section routes through here — see
        // ReadNoteNavigation's doc comment for why a singleton instead of a threaded callback.
        // Opens the note and hands ReadView the surface to scroll/select once it's active; ReadView
        // clears pendingReadScrollTarget itself once it's consumed it (see ReadView+Lifecycle.swift).
        .onChange(of: readNoteNavigation.pendingTarget) { _, target in
            guard let target, let note = notesStore.note(withID: target.noteID) else { return }
            selectedReadNote = note
            lastActiveNoteID = note.id.uuidString
            selectedTab = .read
            pendingReadScrollTarget = target
            readNoteNavigation.pendingTarget = nil
        }
        // "Sing with Kioku" (PlayRandomNoteIntent) while the app is already running.
        .onChange(of: readNoteNavigation.isRandomPlaybackRequested) { _, _ in
            playRandomAudioNoteIfRequested()
        }
        // The breakdown sheet's shuffle button, over the Read tab.
        .onChange(of: readNoteNavigation.isRandomBreakdownRequested) { _, _ in
            openRandomBreakdownIfRequested()
        }
        // The Read tab's shuffle button.
        .onChange(of: readNoteNavigation.isRandomNoteRequested) { _, _ in
            openRandomNoteIfRequested()
        }
        // Bump the segmenter revision so ReadView re-segments existing text with the new strategy.
        .onChange(of: segmentationStrategySetting) { _, _ in
            rebuildReadResources()
        }
        // A custom word added, edited or removed: the rebuild writes the new list into the
        // dictionary first (CustomWordApplier), then re-segments with it. A list the latest
        // rebuild already applied (the launch-time built-in sync) starts nothing: two concurrent
        // rebuilds doubled the launch's ~20 s trie build and wrote the dictionary file at once.
        .onChange(of: customWordStore.words) { _, words in
            guard words != customWordsInLatestRebuild else { return }
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
        // Shortcuts / Siri requests (new note, review, lookups); see IntentHooks.
        .modifier(IntentHooks(perform: performIntentRequest))
        // Spotlight follows the library and routes tapped results (see SpotlightHooks).
        .modifier(SpotlightHooks(
            notes: notesStore.notes,
            words: wordsStore.words,
            dictionaryReady: readResources.ready,
            sync: syncSpotlight,
            open: openSpotlightResult
        ))
        // Refresh WOTD when the underlying saved-word set changes.
        .onChange(of: wordsStore.words) { _, _ in
            guard readResources.ready else { return }
            scheduleWotdRefresh(reason: "words changed", delayNanoseconds: 500_000_000, forceRefresh: true)
        }
        // Probe the pasteboard whenever the app becomes active; reads only the change counter.
        .onChange(of: scenePhase) { _, newPhase in
            // Marks suspensions so a long gap in the timing log reads as time spent in the background.
            StartupTimer.mark("scenePhase → \(newPhase)")
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
        // Non-blocking status banner while dictionary.sqlite downloads (see
        // DictionaryDownloadManager) — every tab underneath stays fully usable. A full-screen
        // gate would violate AGENTS.md's "mandatory network dependency" non-goal and its
        // "dictionary lookup failure must not block editing" failure boundary; dictionaryStore
        // staying nil already degrades dictionary-dependent views gracefully on its own.
        .overlay(alignment: .bottom) {
            if !dictionaryDownloadManager.isInstalled || dictionaryDownloadManager.progress != nil {
                DictionaryDownloadBanner(downloadManager: dictionaryDownloadManager) {
                    Task { await downloadDictionaryAndRebuildIfNeeded() }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: dictionaryDownloadManager.isInstalled)
    }

    // Downloads dictionary.sqlite if needed and rebuilds the read resources once it succeeds,
    // so DictionaryStore() (which fails silently until the file is on disk) gets a working
    // dictionaryStore without requiring a relaunch. Shared by the onAppear kickoff and the
    // download banner's Retry button. Early-returns when already installed: downloadIfNeeded()
    // itself would also no-op in that case, but without this guard rebuildReadResources() (an
    // expensive full SQLite scan + trie build) would still re-run on every single normal launch,
    // duplicating the rebuild loadReadResourcesIfNeeded() already kicked off moments earlier.
    // Debug builds first ask the dev release whether it has a newer dictionary — except a UI-test
    // launch, which brings its own: asking would flag the pinned release it installed as stale and
    // download the dev one over it, rebuilding everything a second time while the tests wait.
    private func downloadDictionaryAndRebuildIfNeeded() async {
        #if DEBUG
        if UITestDictionaryInstaller.isUITestLaunch == false {
            await dictionaryDownloadManager.checkForDevUpdate()
        }
        #endif
        guard !dictionaryDownloadManager.isInstalled || dictionaryDownloadManager.updateAvailable else { return }
        if await dictionaryDownloadManager.downloadIfNeeded() {
            rebuildReadResources()
        }
    }

    // Performs a request an App Intent left on IntentRouter. Review requests move Learn's pager
    // (its stored page index) to the activity and show the tab; the Start button there begins it.
    private func performIntentRequest(_ request: IntentRequest) {
        switch request {
        case .createNote(let title, let text):
            let note = Note(title: title, content: text)
            notesStore.addNote(note)
            selectedReadNote = note
            lastActiveNoteID = note.id.uuidString
            selectedTab = .read
        case .startReview(let page):
            UserDefaults.standard.set(page.rawValue, forKey: LearnPagerView.storedPageIndexKey)
            selectedTab = .learn
        case .lookUp(let text):
            routeToWords(.search(text))
        }
    }

    // Asks the Spotlight indexer to reconcile with the current notes and words. Words wait for the
    // dictionary so their results carry readings and meanings.
    private func syncSpotlight() {
        SpotlightIndexer.shared.scheduleSync(
            notes: notesStore.notes,
            words: wordsStore.words,
            store: readResources.ready ? readResources.dictionaryStore : nil
        )
    }

    // Opens the note or word behind a tapped Spotlight result. A word that has since been
    // unsaved still opens its dictionary detail; a note that was deleted is ignored.
    private func openSpotlightResult(_ rawIdentifier: String) {
        switch SpotlightIdentifier(rawValue: rawIdentifier) {
        case .word(let entryID):
            routeToWords(.detail(entryID: entryID, surface: wordsStore.words.first { $0.canonicalEntryID == entryID }?.surface))
        case .note(let id):
            guard notesStore.note(withID: id) != nil else { return }
            readNoteNavigation.pendingTarget = ReadNoteTarget(noteID: id, surface: "")
        case nil:
            AppLog.error(.storage, "[ContentView] unrecognised Spotlight identifier \(rawIdentifier)")
        }
    }

    // Reads the pasteboard, switches to Words, and populates the search field with the clipboard content.
    private func handleClipboardLookup() {
        guard let content = clipboardCoordinator.consumeClipboard() else { return }
        routeToWords(.search(content))
    }

    // Switches to Words and arms pendingWordsRoute, deferred one runloop tick so the tab
    // switch's own view update lands before WordsView's onChange(of: pendingRoute) fires —
    // the three call sites that route into Words all need this same ordering.
    private func routeToWords(_ route: WordsRoute) {
        selectedTab = .words
        DispatchQueue.main.async {
            pendingWordsRoute = route
        }
    }

    // MARK: - ReadView / NotesView callback handlers
    //
    // Extracted from inline closures so the TabView body keeps a flat, type-checkable shape.
    // SwiftUI's type inferencer chokes on view constructors that accumulate too many
    // closures (each one a fresh `(some View) -> some View` to resolve).

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

    // Notes tab's Import Audio: switch to Read, which transcribes the file into a new note there.
    private func handleAudioImported(_ url: URL) {
        pendingReadAudioImportURL = url
        selectedTab = .read
    }

    // Serves PlayRandomNoteIntent: opens a random note whose audio file exists in Read and asks
    // ReadView to start playing it. Prefers a note other than the one already open, so asking
    // again moves on to a different song.
    private func playRandomAudioNoteIfRequested() {
        guard readNoteNavigation.isRandomPlaybackRequested else { return }
        readNoteNavigation.isRandomPlaybackRequested = false
        let candidates = notesStore.notes.filter { note in
            guard let attachmentID = note.audioAttachmentID else { return false }
            return NotesAudioStore.shared.audioURL(for: attachmentID) != nil
        }
        let others = candidates.filter { $0.id.uuidString != lastActiveNoteID }
        guard let note = (others.isEmpty ? candidates : others).randomElement() else {
            AppLog.info(.audioPlayback, "[ContentView] random playback requested but no note has audio")
            return
        }
        selectedReadNote = note
        lastActiveNoteID = note.id.uuidString
        selectedTab = .read
        pendingReadAutoplayNoteID = note.id
    }

    // Serves the breakdown's shuffle button and the Read tab's Random Breakdown: opens a random note
    // that has a breakdown in Read with its breakdown sheet up, playing from the top. Prefers a note other than the one already open, like
    // playRandomAudioNoteIfRequested, so tapping again moves on to a different song.
    private func openRandomBreakdownIfRequested() {
        guard readNoteNavigation.isRandomBreakdownRequested else { return }
        readNoteNavigation.isRandomBreakdownRequested = false
        let candidates = notesStore.notes.filter { note in
            songBreakdownStore.breakdown(forNoteID: note.id)?.lines.isEmpty == false
        }
        let others = candidates.filter { $0.id.uuidString != lastActiveNoteID }
        guard let note = (others.isEmpty ? candidates : others).randomElement() else {
            AppLog.info(.audioPlayback, "[ContentView] random breakdown requested but no note has a breakdown")
            return
        }
        selectedReadNote = note
        lastActiveNoteID = note.id.uuidString
        selectedTab = .read
        pendingReadScrollTarget = ReadNoteTarget(noteID: note.id, surface: "", destination: .breakdown, autoplay: true)
    }

    // Serves the Read tab's shuffle button: opens a random note in Read, preferring one other than
    // the note already open so tapping again always moves on.
    private func openRandomNoteIfRequested() {
        guard readNoteNavigation.isRandomNoteRequested else { return }
        readNoteNavigation.isRandomNoteRequested = false
        let candidates = notesStore.notes
        let others = candidates.filter { $0.id.uuidString != lastActiveNoteID }
        guard let note = (others.isEmpty ? candidates : others).randomElement() else {
            AppLog.info(.audioPlayback, "[ContentView] random note requested but there are no notes")
            return
        }
        selectedReadNote = note
        lastActiveNoteID = note.id.uuidString
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
        // Already-learned words have nothing left to teach, so they'd only be a wasted notification.
        let learnedEntryIDs = wordsStore.learned
        let words = wordsStore.words.filter { learnedEntryIDs.contains($0.canonicalEntryID) == false }
        let store = readResources.dictionaryStore
        let enabled = UserDefaults.standard.bool(forKey: WordOfTheDayScheduler.enabledKey)
        let hour = UserDefaults.standard.object(forKey: WordOfTheDayScheduler.hourKey) != nil
            ? UserDefaults.standard.integer(forKey: WordOfTheDayScheduler.hourKey)
            : 9
        let minute = UserDefaults.standard.integer(forKey: WordOfTheDayScheduler.minuteKey)

        wotdRefreshTask = Task.detached(priority: .utility) {
            if delayNanoseconds > 0 {
                // Sleep only throws on cancellation, which the isCancelled check below handles.
                try? await Task.sleep(nanoseconds: delayNanoseconds)
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
        let currentRevision = readResources.segmenterRevision
        let customWords = customWordStore.words
        customWordsInLatestRebuild = customWords
        Task.detached(priority: .userInitiated) {
            // Custom Words go into the dictionary file before anything reads it. A failure leaves
            // the file as it was: lookups and segmentation work, minus the list.
            if DictionaryDownloadManager.isInstalled {
                do {
                    try StartupTimer.measure("CustomWordApplier.apply") {
                        try CustomWordApplier.apply(customWords, toDatabaseAt: DictionaryDownloadManager.installedDatabaseURL)
                    }
                } catch {
                    AppLog.error(.dictionary, "applying custom words failed: \(error)")
                }
            }

            // Stage 1 — fast path: open the read-only SQLite handle so the dictionary search bar is
            // usable at once.
            let earlyStore = try? DictionaryStore()
            if let earlyStore {
                await MainActor.run {
                    if readResources.dictionaryStore == nil {
                        readResources.dictionaryStore = earlyStore
                        StartupTimer.mark("dictionaryStore published (fast path)")
                    }
                }
            }

            // The surface-reading/frequency map (~0.8 s scan) on the fast-path connection, beside
            // Stage 2 rather than ahead of it, published as soon as it lands so the lookup/split
            // frequency readout doesn't wait for the trie and lexicon.
            async let earlyReadingData: [String: SurfaceReadingData]? = {
                guard let earlyStore else { return nil }
                let readingData = try? StartupTimer.measure("fetchSurfaceReadingData (early)") {
                    try earlyStore.fetchSurfaceReadingData()
                }
                if let readingData {
                    await MainActor.run {
                        readResources.surfaceReadingData = SurfaceReadingDataMap(readingData)
                        StartupTimer.mark("surfaceReadingData published (early)")
                    }
                }
                return readingData
            }()

            // Stage 2 — slow path: full segmenter build + DictionaryStore prewarming.
            let result = await Self.makeReadResources()
            let rankStore = result.dictionaryStore

            // The lexicon needs the reading map; a failed early scan is retried on Stage 2's store.
            var surfaceReadingData = await earlyReadingData ?? [:]
            if surfaceReadingData.isEmpty, let store = result.dictionaryStore {
                do { surfaceReadingData = try StartupTimer.measure("fetchSurfaceReadingData") {
                    try store.fetchSurfaceReadingData()
                }} catch { AppLog.error(.dictionary, "fetchSurfaceReadingData failed: \(error)") }
            }
            var lexicon: Lexicon?
            if let deinflector = result.deinflector {
                lexicon = StartupTimer.measure("Lexicon.init") {
                    Lexicon(
                        dictionaryStore: result.dictionaryStore,
                        segmenter: result.segmenter,
                        deinflector: deinflector,
                        surfaceReadingData: surfaceReadingData
                    )
                }
            } else {
                AppLog.error(.dictionary, "Lexicon data surface initialization failed: missing deinflector")
            }
            let publishedLexicon = lexicon
            let publishedReadingData = SurfaceReadingDataMap(surfaceReadingData)
            let builtSegmenter = result.segmenter
            let builtStore = result.dictionaryStore
            let builtKanjiReadingFallback = result.kanjiReadingFallback
            await MainActor.run {
                // Preserve the placeholder Segmenter's identity: any closure that captured a reference to it before this
                // point — e.g. a SwiftUI view's implicit `self` capture inside a UIKit-bridged
                // tap callback built before startup finished — keeps seeing the SAME object,
                // now populated with real data, instead of being stuck with an empty trie
                // forever because readResources.segmenter got replaced out from under it.
                let publishedSegmenter: any TextSegmenting
                if let existingSegmenter = readResources.segmenter as? Segmenter,
                   let newSegmenter = builtSegmenter as? Segmenter {
                    existingSegmenter.reconfigure(from: newSegmenter)
                    publishedSegmenter = existingSegmenter
                } else {
                    publishedSegmenter = builtSegmenter
                }

                readResources = ReadResources(
                    segmenter: publishedSegmenter,
                    dictionaryStore: builtStore,
                    lexicon: publishedLexicon,
                    surfaceReadingData: publishedReadingData,
                    kanjiReadingFallback: builtKanjiReadingFallback,
                    // Filled by the follow-up below: nothing on the startup path reads it.
                    frequencyRankBySurface: readResources.frequencyRankBySurface,
                    // Ready only with a dictionary behind the segmenter. Without one (a fresh
                    // install whose download hasn't finished) the trie is empty, and the Read tab
                    // would segment the open note character by character and persist that, after
                    // which the real dictionary only refreshes furigana over the bad segments.
                    ready: builtStore != nil,
                    segmenterRevision: currentRevision + 1
                )
                StartupTimer.mark("readResourcesReady published to UI")
            }

            // Per-ENTRY best frequency rank, propagated to every spelling of the entry. Backs the
            // lookup and split-editor frequency display, where a kana split piece like こと / する
            // should report its word's rank instead of rendering a bare "–". NOT what the segmenter
            // scores with: it reads the rank of each surface as written, via
            // Segmenter(…frequenciesFrom:). Built after publishing so its ~0.4 s doesn't delay the
            // lexicon, which the saved-word coloring waits on.
            if let store = rankStore {
                let ranks: [String: Int] = StartupTimer.measure("frequencyRankBySurface build") {
                    (try? store.fetchBestRankBySurface()) ?? [:]
                }
                await MainActor.run {
                    readResources.frequencyRankBySurface = FrequencyRankMap(ranks)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
