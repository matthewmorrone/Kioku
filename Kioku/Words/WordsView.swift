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
    case detail(entryID: Int64, surface: String?)
    case search(String)
}

// Renders the saved-word list screen for the Words tab.
// Major sections: search bar, saved/history tab picker, word rows, toolbar.
struct WordsView: View {
    let dictionaryStore: DictionaryStore?
    // Receives cross-tab routing requests from ContentView.
    var pendingRoute: Binding<WordsRoute?> = .constant(nil)

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var historyStore: HistoryStore

    @State private var selectedDetailWord: SavedWord?
    @State private var activeFilterNoteIDs: Set<UUID> = []
    @State private var activeFilterListIDs: Set<UUID> = []
    @State private var isFilterSheetPresented = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedWordIDs: Set<Int64> = []
    @State private var isBatchRemoveConfirmPresented = false
    @State private var isBatchRemoveHistoryConfirmPresented = false
    @State private var isBatchListSheetPresented = false
    @State private var isCSVImportPresented = false
    @State private var selectedHistoryIDs: Set<Int64> = []
    @State private var activeTab: WordsTab = .saved
    @AppStorage("savedWordsSortOrder") private var savedSortOrder: String = WordsSortOrder.newestFirst.rawValue
    @AppStorage("historySortOrder") private var historySortOrderRaw: String = WordsSortOrder.newestFirst.rawValue
    @State private var searchText = ""
    @State private var searchMode: DictionarySearchMode = .japanese
    @State private var searchSortMode: DictionarySearchSortMode = .relevance
    @State private var searchCommonWordsOnly = false
    @State private var searchSelectedPartsOfSpeech: Set<String> = []
    @State private var areSearchFiltersExpanded = false

    private var savedSort: WordsSortOrder { WordsSortOrder(rawValue: savedSortOrder) ?? .newestFirst }
    private var historySort: WordsSortOrder { WordsSortOrder(rawValue: historySortOrderRaw) ?? .newestFirst }
    @State private var searchResults: [DictionaryEntry] = []
    @State private var searchTask: Task<Void, Never>?

    // Builds the word model used by WordDetailView, reusing a saved word when available and
    // otherwise synthesizing a temporary detail target from the route payload or dictionary entry.
    private func detailWord(entryID: Int64, surfaceHint: String?) -> SavedWord? {
        if let saved = wordsStore.words.first(where: { $0.canonicalEntryID == entryID }) {
            return saved
        }

        if let surfaceHint, surfaceHint.isEmpty == false {
            return SavedWord(canonicalEntryID: entryID, surface: surfaceHint)
        }

        guard let entry = try? dictionaryStore?.lookupEntry(entryID: entryID) else {
            return nil
        }

        let surface = entry.kanjiForms.first?.text
            ?? entry.kanaForms.first?.text
            ?? entry.matchedSurface

        guard surface.isEmpty == false else { return nil }
        return SavedWord(canonicalEntryID: entryID, surface: surface)
    }

    // Applies a cross-tab route, either by opening a word detail or populating the search query.
    private func consumePendingRoute(_ route: WordsRoute?) {
        guard let route else { return }

        switch route {
        case let .detail(entryID, surface):
            if let word = detailWord(entryID: entryID, surfaceHint: surface) {
                activeTab = .saved
                selectedDetailWord = word
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
            .toolbar {
                toolbarContent
            }
            .confirmationDialog(
                "Remove \(selectedWordIDs.count) word\(selectedWordIDs.count == 1 ? "" : "s")?",
                isPresented: $isBatchRemoveConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    for id in selectedWordIDs {
                        wordsStore.remove(id: id)
                    }
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
                    for id in selectedHistoryIDs {
                        historyStore.remove(id: id)
                    }
                    selectedHistoryIDs.removeAll()
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(item: $selectedDetailWord) { word in
            WordDetailView(word: word, dictionaryStore: dictionaryStore)
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
        .onChange(of: activeTab) { _, _ in
            editMode = .inactive
            selectedWordIDs.removeAll()
            selectedHistoryIDs.removeAll()
        }
        .onChange(of: searchText) { _, newValue in
            editMode = .inactive
            selectedWordIDs.removeAll()
            selectedHistoryIDs.removeAll()
            startSearchTask(for: newValue)
        }
        .onChange(of: searchMode) { _, _ in
            startSearchTask(for: searchText)
        }
    }

    // MARK: - List content sections

    @ViewBuilder
    private var savedWordsContent: some View {
        if visibleWords.isEmpty {
            Text("No saved words yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(visibleWords, id: \.canonicalEntryID) { savedWord in
                WordRowView(
                    word: savedWord,
                    lists: wordListsStore.lists,
                    onOpenDetails: {
                        guard editMode == .inactive else { return }
                        selectedDetailWord = savedWord
                    },
                    onToggleList: { listID in
                        wordsStore.toggleListMembership(wordID: savedWord.canonicalEntryID, listID: listID)
                    },
                    onRemove: { wordsStore.remove(id: savedWord.canonicalEntryID) }
                )
                .tag(savedWord.canonicalEntryID)
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if historyStore.entries.isEmpty {
            Text("No lookup history yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sortedHistory) { entry in
                historyRow(entry)
                    .tag(entry.canonicalEntryID)
            }
        }
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        Section {
            searchFiltersSection
        }
        .listRowSeparator(.hidden)

        if filteredSearchResults.isEmpty {
            Section {
                Text(searchText.isEmpty ? "" : "No results")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(filteredSearchResults, id: \.entryId) { entry in
                    DictionarySearchResultRow(
                        entry: entry,
                        isSaved: isSaved(entry),
                        onToggleSave: { toggleSave(entry) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openSearchResult(entry)
                    }
                }
            } header: {
                Text("\(filteredSearchResults.count) Result\(filteredSearchResults.count == 1 ? "" : "s")")
            }
        }
    }

    // Renders the search-mode picker plus optional live result filters for dictionary search.
    private var searchFiltersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Search Mode", selection: $searchMode) {
                ForEach(DictionarySearchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            DisclosureGroup(isExpanded: $areSearchFiltersExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Common words only", isOn: $searchCommonWordsOnly)

                    Picker("Sort", selection: $searchSortMode) {
                        ForEach(DictionarySearchSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Part of speech")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(availableSearchPartsOfSpeech, id: \.self) { label in
                                Button {
                                    toggleSearchPartOfSpeech(label)
                                } label: {
                                    Label(label, systemImage: searchSelectedPartsOfSpeech.contains(label) ? "checkmark" : "")
                                }
                            }
                        } label: {
                            Text(searchPartOfSpeechSummary)
                                .font(.caption)
                        }
                        .disabled(availableSearchPartsOfSpeech.isEmpty)
                    }

                    Button("Reset Filters") {
                        resetSearchControls()
                    }
                    .disabled(hasActiveSearchControls == false)
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 8) {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    Spacer()
                    if hasActiveSearchControls {
                        Text("Active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    // Renders one history entry row with swipe-to-delete and a context menu matching the saved-words CRUD pattern.
    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.surface)
                .font(.headline)

            Spacer(minLength: 0)

            Button {
                toggleSaveHistory(entry)
            } label: {
                let saved = isSavedByID(entry.canonicalEntryID)
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? Color.yellow : Color.secondary)
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSavedByID(entry.canonicalEntryID) ? "Unsave" : "Save")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDetailWord = wordForHistory(entry)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                historyStore.remove(id: entry.canonicalEntryID)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.surface
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                selectedDetailWord = wordForHistory(entry)
            } label: {
                Label("Look Up", systemImage: "magnifyingglass")
            }

            Button {
                selectedDetailWord = wordForHistory(entry)
            } label: {
                Label("Open Details", systemImage: "info.circle")
            }

            Divider()

            let saved = isSavedByID(entry.canonicalEntryID)
            Button {
                toggleSaveHistory(entry)
            } label: {
                Label(saved ? "Unsave" : "Save", systemImage: saved ? "star.slash" : "star")
            }

            Button(role: .destructive) {
                historyStore.remove(id: entry.canonicalEntryID)
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // CSV import floats to the leading side, separate from CRUD controls.
        if activeTab == .saved && editMode == .inactive && searchText.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isCSVImportPresented = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Import CSV")
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if searchText.isEmpty {
                if editMode == .active {
                    // Batch delete for whichever tab is active.
                    Button {
                        if activeTab == .saved {
                            isBatchRemoveConfirmPresented = true
                        } else {
                            isBatchRemoveHistoryConfirmPresented = true
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(activeTab == .saved ? selectedWordIDs.isEmpty : selectedHistoryIDs.isEmpty)
                    .accessibilityLabel("Delete Selected")

                    // Select all / deselect all for whichever tab is active.
                    Button {
                        if activeTab == .saved {
                            if selectedWordIDs.count == visibleWords.count {
                                selectedWordIDs.removeAll()
                            } else {
                                selectedWordIDs = Set(visibleWords.map(\.canonicalEntryID))
                            }
                        } else {
                            if selectedHistoryIDs.count == historyStore.entries.count {
                                selectedHistoryIDs.removeAll()
                            } else {
                                selectedHistoryIDs = Set(historyStore.entries.map(\.canonicalEntryID))
                            }
                        }
                    } label: {
                        let allSelected = activeTab == .saved
                            ? selectedWordIDs.count == visibleWords.count
                            : selectedHistoryIDs.count == historyStore.entries.count
                        Image(systemName: allSelected ? "minus.circle" : "circle.dashed.inset.filled")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(
                        (activeTab == .saved
                            ? selectedWordIDs.count == visibleWords.count
                            : selectedHistoryIDs.count == historyStore.entries.count)
                        ? "Deselect All" : "Select All"
                    )
                }

                // Edit mode toggle — shown for saved always, for history only when non-empty.
                if activeTab == .saved || historyStore.entries.isEmpty == false {
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                        if editMode == .inactive {
                            selectedWordIDs.removeAll()
                            selectedHistoryIDs.removeAll()
                        }
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark.circle" : "pencil")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(editMode == .active ? "Done Editing" : "Edit")
                }

                // Sort menu — available on both tabs when not in edit mode.
                if editMode == .inactive {
                    Menu {
                        let currentSort = activeTab == .saved ? savedSort : historySort
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.newestFirst.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.newestFirst.rawValue }
                        } label: {
                            if currentSort == .newestFirst {
                                Label("Newest First", systemImage: "checkmark")
                            } else {
                                Text("Newest First")
                            }
                        }
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.oldestFirst.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.oldestFirst.rawValue }
                        } label: {
                            if currentSort == .oldestFirst {
                                Label("Oldest First", systemImage: "checkmark")
                            } else {
                                Text("Oldest First")
                            }
                        }
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.aToZ.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.aToZ.rawValue }
                        } label: {
                            if currentSort == .aToZ {
                                Label("A to Z", systemImage: "checkmark")
                            } else {
                                Text("A to Z")
                            }
                        }
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.zToA.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.zToA.rawValue }
                        } label: {
                            if currentSort == .zToA {
                                Label("Z to A", systemImage: "checkmark")
                            } else {
                                Text("Z to A")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Sort")
                }

                // Filter / list management — only meaningful for saved words.
                Button {
                    if activeTab == .saved && editMode == .active && !selectedWordIDs.isEmpty {
                        isBatchListSheetPresented = true
                    } else {
                        isFilterSheetPresented = true
                    }
                } label: {
                    Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(activeTab == .saved && editMode == .active && !selectedWordIDs.isEmpty ? "Manage Lists for Selection" : "Filter by List")
            }
        }
    }

    // MARK: - Helpers

    // True when any filter is active across notes or lists.
    private var isFilterActive: Bool {
        !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty
    }

    // Returns saved words filtered by active note/list selection and sorted by the current saved sort order.
    private var visibleWords: [SavedWord] {
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
    private var sortedHistory: [HistoryEntry] {
        switch historySort {
        case .newestFirst: return historyStore.entries.sorted { $0.lookedUpAt > $1.lookedUpAt }
        case .oldestFirst: return historyStore.entries.sorted { $0.lookedUpAt < $1.lookedUpAt }
        case .aToZ:        return historyStore.entries.sorted { $0.surface < $1.surface }
        case .zToA:        return historyStore.entries.sorted { $0.surface > $1.surface }
        }
    }

    // Sorts a saved-word array by the given order.
    private func sorted(_ words: [SavedWord], by order: WordsSortOrder) -> [SavedWord] {
        switch order {
        case .newestFirst: return words.sorted { $0.savedAt > $1.savedAt }
        case .oldestFirst: return words.sorted { $0.savedAt < $1.savedAt }
        case .aToZ:        return words.sorted { $0.surface < $1.surface }
        case .zToA:        return words.sorted { $0.surface > $1.surface }
        }
    }

    // Returns true when the given entry is already in the saved words list.
    private func isSaved(_ entry: DictionaryEntry) -> Bool {
        wordsStore.words.contains { $0.canonicalEntryID == entry.entryId }
    }

    // Returns true when the given canonical entry id is in the saved words list.
    private func isSavedByID(_ id: Int64) -> Bool {
        wordsStore.words.contains { $0.canonicalEntryID == id }
    }

    // Saves or removes an entry from search results.
    private func toggleSave(_ entry: DictionaryEntry) {
        let surface = entry.primarySearchSurface
        if isSaved(entry) {
            wordsStore.remove(id: entry.entryId)
        } else {
            wordsStore.add(SavedWord(canonicalEntryID: entry.entryId, surface: surface))
        }
    }

    // Saves or removes a word surfaced from the history list.
    private func toggleSaveHistory(_ entry: HistoryEntry) {
        if isSavedByID(entry.canonicalEntryID) {
            wordsStore.remove(id: entry.canonicalEntryID)
        } else {
            wordsStore.add(SavedWord(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface))
        }
    }

    // Returns the saved word for a history entry if it exists, otherwise a minimal SavedWord for display.
    private func wordForHistory(_ entry: HistoryEntry) -> SavedWord {
        wordsStore.words.first { $0.canonicalEntryID == entry.canonicalEntryID }
            ?? SavedWord(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
    }

    // Returns available POS labels from the current raw search result set.
    private var availableSearchPartsOfSpeech: [String] {
        var seen = Set<String>()
        var labels: [String] = []

        for entry in searchResults {
            for label in entry.searchPartOfSpeechLabels where seen.insert(label).inserted {
                labels.append(label)
            }
        }

        return labels
    }

    // Returns the current result set after applying common-word, POS, and sort controls.
    private var filteredSearchResults: [DictionaryEntry] {
        let filtered = searchResults.filter { entry in
            if searchCommonWordsOnly && entry.isCommonSearchEntry == false {
                return false
            }

            if searchSelectedPartsOfSpeech.isEmpty == false {
                let entryParts = Set(entry.searchPartOfSpeechLabels)
                if entryParts.isDisjoint(with: searchSelectedPartsOfSpeech) {
                    return false
                }
            }

            return true
        }

        switch searchSortMode {
        case .relevance:
            return filtered
        case .commonFirst:
            return filtered.enumerated().sorted { lhs, rhs in
                if lhs.element.isCommonSearchEntry != rhs.element.isCommonSearchEntry {
                    return lhs.element.isCommonSearchEntry && rhs.element.isCommonSearchEntry == false
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        case .alphabetical:
            return filtered.sorted {
                $0.primarySearchSurface.localizedCaseInsensitiveCompare($1.primarySearchSurface) == .orderedAscending
            }
        }
    }

    // Describes the active POS selection in the search filter summary line.
    private var searchPartOfSpeechSummary: String {
        if searchSelectedPartsOfSpeech.isEmpty {
            return availableSearchPartsOfSpeech.isEmpty ? "Unavailable" : "Any"
        }

        return searchSelectedPartsOfSpeech.sorted().joined(separator: ", ")
    }

    // True when any live dictionary-search control is narrowing or reordering the result set.
    private var hasActiveSearchControls: Bool {
        searchCommonWordsOnly || searchSortMode != .relevance || searchSelectedPartsOfSpeech.isEmpty == false
    }

    // Starts or replaces the debounced dictionary-search task for the current query and mode.
    private func startSearchTask(for query: String) {
        searchTask?.cancel()
        searchTask = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            searchResults = []
            return
        }

        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }

            guard let store = dictionaryStore, Task.isCancelled == false else { return }
            let mode = searchMode
            let results = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let entries = (try? store.searchEntries(term: trimmedQuery, mode: mode)) ?? []
                    continuation.resume(returning: entries)
                }
            }

            guard Task.isCancelled == false,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery,
                  searchMode == mode else {
                return
            }

            searchResults = results
            pruneUnavailableSearchPartsOfSpeech()
        }
    }

    // Removes POS selections that are no longer available after a new search result set arrives.
    private func pruneUnavailableSearchPartsOfSpeech() {
        searchSelectedPartsOfSpeech.formIntersection(Set(availableSearchPartsOfSpeech))
    }

    // Toggles one POS label in the search filter menu.
    private func toggleSearchPartOfSpeech(_ label: String) {
        if searchSelectedPartsOfSpeech.contains(label) {
            searchSelectedPartsOfSpeech.remove(label)
        } else {
            searchSelectedPartsOfSpeech.insert(label)
        }
    }

    // Resets live dictionary-search controls back to the default broad result set.
    private func resetSearchControls() {
        searchCommonWordsOnly = false
        searchSortMode = .relevance
        searchSelectedPartsOfSpeech = []
    }

    // Opens one live search result in the detail sheet and records it in lookup history.
    private func openSearchResult(_ entry: DictionaryEntry) {
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        selectedDetailWord = detailWord(entryID: entry.entryId, surfaceHint: entry.primarySearchSurface)
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
