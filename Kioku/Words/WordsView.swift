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

// Renders the saved-word list screen for the Words tab.
// Major sections: search bar, saved/history tab picker, word rows, toolbar.
struct WordsView: View {
    let dictionaryStore: DictionaryStore?
    // Receives a canonicalEntryID from a notification deep link; opens its word detail when set.
    var deepLinkedEntryID: Binding<Int64?> = .constant(nil)

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

    private var savedSort: WordsSortOrder { WordsSortOrder(rawValue: savedSortOrder) ?? .newestFirst }
    private var historySort: WordsSortOrder { WordsSortOrder(rawValue: historySortOrderRaw) ?? .newestFirst }
    @State private var searchResults: [DictionaryEntry] = []
    @State private var searchTask: Task<Void, Never>?

    // Consumes a pending deep link by switching to Saved and opening the matching word detail.
    private func consumeDeepLinkEntryID(_ entryID: Int64?) {
        guard let entryID else { return }
        if let word = wordsStore.words.first(where: { $0.canonicalEntryID == entryID }) {
            activeTab = .saved
            selectedDetailWord = word
        }
        deepLinkedEntryID.wrappedValue = nil
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
            consumeDeepLinkEntryID(deepLinkedEntryID.wrappedValue)
        }
        // Opens the detail sheet for a word deep-linked from a Word of the Day notification.
        .onChange(of: deepLinkedEntryID.wrappedValue) { _, entryID in
            consumeDeepLinkEntryID(entryID)
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
            searchTask?.cancel()
            searchTask = nil
            if newValue.isEmpty {
                searchResults = []
                return
            }
            editMode = .inactive
            selectedWordIDs.removeAll()
            searchTask = Task {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard let store = dictionaryStore, Task.isCancelled == false else { return }
                let query = newValue
                let hasKanji = ScriptClassifier.containsKanji(query)
                let results = await Task.detached(priority: .userInitiated) {
                    var entries: [DictionaryEntry] = []
                    if hasKanji {
                        entries += (try? await MainActor.run { try store.lookup(surface: query, mode: .kanjiAndKana) }) ?? []
                    }
                    entries += (try? await MainActor.run { try store.lookup(surface: query, mode: .kanaOnly) }) ?? []
                    var seen = Set<Int64>()
                    return entries.filter { seen.insert($0.entryId).inserted }
                }.value
                searchResults = results
            }
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
        if searchResults.isEmpty {
            Text(searchText.isEmpty ? "" : "No results")
                .foregroundStyle(.secondary)
        } else {
            ForEach(searchResults, id: \.entryId) { entry in
                DictionarySearchResultRow(
                    entry: entry,
                    isSaved: isSaved(entry),
                    onToggleSave: { toggleSave(entry) }
                )
            }
        }
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
        let surface = entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? entry.matchedSurface
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
}

#Preview {
    ContentView(selectedTab: .words)
}
