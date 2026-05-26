import SwiftUI

// Tabs available in the Words screen.
enum WordsTab { case saved, history }

// Sort options for both saved words and history.
enum WordsSortOrder: String {
    case newestFirst
    case oldestFirst
    case aToZ
    case zToA
}

// Cross-tab routing for the Words screen.
enum WordsRoute: Equatable {
    case detail(entryID: Int64, surface: String?, reading: String? = nil, sublatticePaths: [[String]] = [])
    case search(String)
}

// Renders the saved-word list screen for the Words tab.
// Major sections: search bar, saved/history tab picker, word rows, toolbar.
struct WordsView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Receives cross-tab routing requests from ContentView.
    var pendingRoute: Binding<WordsRoute?> = .constant(nil)

    @EnvironmentObject var wordsStore: WordsStore
    @EnvironmentObject var wordListsStore: WordListsStore
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var historyStore: HistoryStore

    @State var selectedDetailWord: SavedWord?
    // Reading that was active in the lookup sheet when this word detail was opened, if available.
    @State var selectedDetailReading: String?
    @State var selectedDetailSublatticePaths: [[String]] = []
    @State var activeFilterNoteIDs: Set<UUID> = []
    @State var activeFilterListIDs: Set<UUID> = []
    @State var isFilterSheetPresented = false
    @State var editMode: EditMode = .inactive
    @State var selectedWordIDs: Set<Int64> = []
    @State var isBatchRemoveConfirmPresented = false
    @State var isBatchRemoveHistoryConfirmPresented = false
    @State var isBatchListSheetPresented = false
    @State var isCSVImportPresented = false
    @State var isBrowseFrequencyPresented = false
    @State var isSentenceSearchPresented = false
    @State var isRadicalInputPresented = false
    @State var selectedHistoryIDs: Set<Int64> = []
    @State var activeTab: WordsTab = .saved
    @AppStorage("savedWordsSortOrder") var savedSortOrder: String = WordsSortOrder.newestFirst.rawValue
    @AppStorage("historySortOrder") var historySortOrderRaw: String = WordsSortOrder.newestFirst.rawValue
    @State var searchText = ""
    @State var convertedKana: String? = nil
    @State var searchMode: DictionarySearchMode = .japanese
    @State var searchSortMode: DictionarySearchSortMode = .relevance
    @State var searchCommonWordsOnly = false
    @State var searchSelectedPartsOfSpeech: Set<String> = []
    @State var areSearchFiltersExpanded = false

    var savedSort: WordsSortOrder { WordsSortOrder(rawValue: savedSortOrder) ?? .newestFirst }
    var historySort: WordsSortOrder { WordsSortOrder(rawValue: historySortOrderRaw) ?? .newestFirst }
    @State var searchResults: [DictionaryEntry] = []
    // Populated when the query segments into multiple tokens — switches the search results
    // view from entry-list mode to one-row-per-segment mode (Pleco-style sentence parse).
    @State var parsedSegments: [ParsedSegment] = []
    @State var searchTask: Task<Void, Never>?

    // Builds the word model used by WordDetailView, reusing a saved word when available and
    // otherwise synthesizing a temporary detail target from the route payload or dictionary entry.
    func detailWord(entryID: Int64, surfaceHint: String?) -> SavedWord? {
        if let saved = wordsStore.words.first(where: { $0.canonicalEntryID == entryID }) {
            return saved
        }

        if let surfaceHint, surfaceHint.isEmpty == false {
            return SavedWord(canonicalEntryID: entryID, surface: surfaceHint)
        }

        guard let entry = try? dictionaryStore?.lookupEntry(entryID: entryID) else {
            return nil
        }

        // matchedSurface reflects how the entry was reached, so prefer it over kanjiForms.first
        // which would otherwise promote kana-routed lookups to kanji.
        let surface = entry.matchedSurface.isEmpty == false
            ? entry.matchedSurface
            : (entry.kanaForms.first?.text ?? entry.kanjiForms.first?.text ?? "")

        guard surface.isEmpty == false else { return nil }
        return SavedWord(canonicalEntryID: entryID, surface: surface)
    }

    // Applies a cross-tab route, either by opening a word detail or populating the search query.
    private func consumePendingRoute(_ route: WordsRoute?) {
        guard let route else { return }

        switch route {
        case let .detail(entryID, surface, reading, sublatticePaths):
            if let word = detailWord(entryID: entryID, surfaceHint: surface) {
                activeTab = .saved
                selectedDetailWord = word
                selectedDetailReading = reading
                selectedDetailSublatticePaths = sublatticePaths
            }

        case let .search(query):
            activeTab = .saved
            selectedDetailWord = nil
            editMode = .inactive
            selectedWordIDs.removeAll()
            selectedHistoryIDs.removeAll()
            searchText = query
        }

        pendingRoute.wrappedValue = nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if searchText.isEmpty {
                    Picker("Tab", selection: $activeTab) {
                        Text("Saved").tag(WordsTab.saved)
                        Text("History").tag(WordsTab.history)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                List(selection: searchText.isEmpty ? (activeTab == .saved ? $selectedWordIDs : $selectedHistoryIDs) : .constant(Set<Int64>())) {
                    if searchText.isEmpty == false {
                        searchResultsContent
                    } else if activeTab == .saved {
                        savedWordsContent
                    } else {
                        historyContent
                    }
                }
                .environment(\.editMode, searchText.isEmpty ? $editMode : .constant(.inactive))
                .animation(.default, value: activeTab)
            }
            .searchable(text: $searchText, prompt: "Search dictionary…")
            .searchSuggestions {
                if let kana = convertedKana, kana != searchText {
                    Label {
                        HStack {
                            Text(kana)
                            Spacer()
                            Text("Tap to search kana")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.right")
                    }
                    .searchCompletion(kana)
                }
            }
            .toolbar {
                toolbarContent
            }
            .confirmationDialog(
                "Remove \(selectedWordIDs.count) word\(selectedWordIDs.count == 1 ? "" : "s")?",
                isPresented: $isBatchRemoveConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    wordsStore.remove(ids: selectedWordIDs)
                    selectedWordIDs.removeAll()
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Remove \(selectedHistoryIDs.count) entr\(selectedHistoryIDs.count == 1 ? "y" : "ies") from history?",
                isPresented: $isBatchRemoveHistoryConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    historyStore.remove(ids: selectedHistoryIDs)
                    selectedHistoryIDs.removeAll()
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(item: $selectedDetailWord, onDismiss: { selectedDetailReading = nil; selectedDetailSublatticePaths = [] }) { word in
            WordDetailView(word: word, reading: selectedDetailReading, dictionaryStore: dictionaryStore, segmenter: segmenter, initialSublatticePaths: selectedDetailSublatticePaths)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .presentationDetents([.large])
        }
        .onAppear {
            consumePendingRoute(pendingRoute.wrappedValue)
        }
        // Applies cross-tab routes from notifications and read-mode lookup actions.
        .onChange(of: pendingRoute.wrappedValue) { _, route in
            consumePendingRoute(route)
        }
        .sheet(isPresented: $isFilterSheetPresented) {
            WordsFilterView(activeFilterNoteIDs: $activeFilterNoteIDs, activeFilterListIDs: $activeFilterListIDs)
                .environmentObject(wordListsStore)
                .environmentObject(wordsStore)
                .environmentObject(notesStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isBatchListSheetPresented) {
            WordsBatchListView(selectedWordIDs: selectedWordIDs)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCSVImportPresented) {
            CSVImportView(dictionaryStore: dictionaryStore)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isBrowseFrequencyPresented) {
            BrowseFrequencyView(
                dictionaryStore: dictionaryStore,
                isSaved: { entryID in wordsStore.words.contains(where: { $0.canonicalEntryID == entryID }) },
                onToggleSave: handleBrowseToggleSave,
                onSelectEntry: handleBrowseSelectEntry
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isSentenceSearchPresented) {
            SentenceSearchView(dictionaryStore: dictionaryStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isRadicalInputPresented) {
            RadicalInputView(
                dictionaryStore: dictionaryStore,
                onSelectKanji: handleRadicalSelectKanji
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: activeTab) { _, _ in
            editMode = .inactive
            selectedWordIDs.removeAll()
            selectedHistoryIDs.removeAll()
        }
        .onChange(of: searchText) { _, newValue in
            editMode = .inactive
            selectedWordIDs.removeAll()
            selectedHistoryIDs.removeAll()
            convertedKana = RomajiToKana.convert(newValue)?.kana
            startSearchTask(for: newValue)
        }
        .onChange(of: searchMode) { _, _ in
            startSearchTask(for: searchText)
        }
    }

    // MARK: - Helpers

    // True when any filter is active across notes or lists.
    var isFilterActive: Bool {
        !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty
    }

    // Returns saved words filtered by active note/list selection and sorted by the current saved sort order.
    var visibleWords: [SavedWord] {
        let filtered: [SavedWord]
        if isFilterActive {
            filtered = wordsStore.words.filter { word in
                let matchesNote = activeFilterNoteIDs.isEmpty || activeFilterNoteIDs.contains { word.sourceNoteIDs.contains($0) }
                let matchesList = activeFilterListIDs.isEmpty || activeFilterListIDs.contains { word.wordListIDs.contains($0) }
                return matchesNote && matchesList
            }
        } else {
            filtered = wordsStore.words
        }
        return sorted(filtered, by: savedSort)
    }

    // Returns history entries sorted by the current history sort order.
    var sortedHistory: [HistoryEntry] {
        switch historySort {
        case .newestFirst: return historyStore.entries.sorted { $0.lookedUpAt > $1.lookedUpAt }
        case .oldestFirst: return historyStore.entries.sorted { $0.lookedUpAt < $1.lookedUpAt }
        case .aToZ:        return historyStore.entries.sorted { $0.surface < $1.surface }
        case .zToA:        return historyStore.entries.sorted { $0.surface > $1.surface }
        }
    }

    // Sorts a saved-word array by the given order.
    func sorted(_ words: [SavedWord], by order: WordsSortOrder) -> [SavedWord] {
        switch order {
        case .newestFirst: return words.sorted { $0.savedAt > $1.savedAt }
        case .oldestFirst: return words.sorted { $0.savedAt < $1.savedAt }
        case .aToZ:        return words.sorted { $0.surface < $1.surface }
        case .zToA:        return words.sorted { $0.surface > $1.surface }
        }
    }

    // Returns true when the given entry is already in the saved words list.
    func isSaved(_ entry: DictionaryEntry) -> Bool {
        wordsStore.words.contains { $0.canonicalEntryID == entry.entryId }
    }

    // Returns true when the given canonical entry id is in the saved words list.
    func isSavedByID(_ id: Int64) -> Bool {
        wordsStore.words.contains { $0.canonicalEntryID == id }
    }

    // Saves or removes an entry from search results.
    func toggleSave(_ entry: DictionaryEntry) {
        wordsStore.toggle(
            canonicalEntryID: entry.entryId,
            storedSurface: entry.primarySearchSurface,
            defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
        )
    }

    // Saves or removes a word surfaced from the history list.
    func toggleSaveHistory(_ entry: HistoryEntry) {
        // History rows lack a resolved DictionaryEntry; resolve once so the smart-default
        // picker can populate selectedSenseIDs at save time.
        let senseIDs: [Int64]
        if let store = dictionaryStore,
           let resolved = try? store.lookupEntry(entryID: entry.canonicalEntryID) {
            senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: resolved)
        } else {
            senseIDs = []
        }
        wordsStore.toggle(
            canonicalEntryID: entry.canonicalEntryID,
            storedSurface: entry.surface,
            defaultSenseIDs: senseIDs
        )
    }

    // Returns the saved word for a history entry if it exists, otherwise a minimal SavedWord for display.
    func wordForHistory(_ entry: HistoryEntry) -> SavedWord {
        wordsStore.words.first { $0.canonicalEntryID == entry.canonicalEntryID }
            ?? SavedWord(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
    }

    // Toggles save/unsave for an entry surfaced in the browse-frequency sheet.
    func handleBrowseToggleSave(_ entry: DictionaryEntry) {
        wordsStore.toggle(
            canonicalEntryID: entry.entryId,
            storedSurface: entry.primarySearchSurface,
            defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
        )
    }

    // Routes a picked kanji from the radical input sheet into the search field on the Words tab.
    func handleRadicalSelectKanji(_ kanji: String) {
        isRadicalInputPresented = false
        searchText = kanji
    }

    // Opens one browse-frequency result in the detail sheet, dismissing the browse sheet first.
    func handleBrowseSelectEntry(_ entry: DictionaryEntry) {
        isBrowseFrequencyPresented = false
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        // Defer to next runloop so the sheet dismissal animation doesn't race the detail presentation.
        DispatchQueue.main.async {
            selectedDetailWord = detailWord(entryID: entry.entryId, surfaceHint: entry.primarySearchSurface)
        }
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
