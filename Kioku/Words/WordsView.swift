import SwiftUI

// Tabs available in the Words screen.
enum WordsTab { case saved, history }

// Renders the saved-word list screen for the Words tab.
// Major sections: search bar, saved/history tab picker, word rows, toolbar.
struct WordsView: View {
    let dictionaryStore: DictionaryStore?

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
    @State private var isBatchListSheetPresented = false
    @State private var activeTab: WordsTab = .saved
    @State private var searchText = ""
    @State private var searchResults: [DictionaryEntry] = []
    @State private var searchTask: Task<Void, Never>?

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

                List(selection: activeTab == .saved && searchText.isEmpty ? $selectedWordIDs : .constant(Set<Int64>())) {
                    if searchText.isEmpty == false {
                        searchResultsContent
                    } else if activeTab == .saved {
                        savedWordsContent
                    } else {
                        historyContent
                    }
                }
                .environment(\.editMode, activeTab == .saved && searchText.isEmpty ? $editMode : .constant(.inactive))
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
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(item: $selectedDetailWord) { word in
            WordDetailView(word: word, lists: wordListsStore.lists, dictionaryStore: dictionaryStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        .onChange(of: activeTab) { _, _ in
            editMode = .inactive
            selectedWordIDs.removeAll()
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
                        entries += (try? store.lookup(surface: query, mode: .kanjiAndKana)) ?? []
                    }
                    entries += (try? store.lookup(surface: query, mode: .kanaOnly)) ?? []
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
            .onMove { fromOffsets, toOffset in
                wordsStore.move(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if historyStore.entries.isEmpty {
            Text("No lookup history yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(historyStore.entries) { entry in
                historyRow(entry)
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

    // Renders one history entry row — surface, relative timestamp, and save toggle.
    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.surface)
                    .font(.headline)
                Text(entry.lookedUpAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

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
            .accessibilityLabel(isSavedByID(entry.canonicalEntryID) ? "Unsave Word" : "Save Word")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDetailWord = wordForHistory(entry)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if activeTab == .saved && searchText.isEmpty {
                if editMode == .active {
                    Button {
                        isBatchRemoveConfirmPresented = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(selectedWordIDs.isEmpty)
                    .accessibilityLabel("Delete Selected Words")

                    Button {
                        if selectedWordIDs.count == visibleWords.count {
                            selectedWordIDs.removeAll()
                        } else {
                            selectedWordIDs = Set(visibleWords.map(\.canonicalEntryID))
                        }
                    } label: {
                        let allSelected = selectedWordIDs.count == visibleWords.count
                        Image(systemName: allSelected ? "minus.circle" : "circle.dashed.inset.filled")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(selectedWordIDs.count == visibleWords.count ? "Deselect All" : "Select All")
                }

                Button {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode == .inactive {
                        selectedWordIDs.removeAll()
                    }
                } label: {
                    Image(systemName: editMode == .active ? "checkmark.circle" : "pencil")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(editMode == .active ? "Done Editing" : "Edit Words")

                Button {
                    if editMode == .active && !selectedWordIDs.isEmpty {
                        isBatchListSheetPresented = true
                    } else {
                        isFilterSheetPresented = true
                    }
                } label: {
                    Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(editMode == .active && !selectedWordIDs.isEmpty ? "Manage Lists for Selection" : "Filter by List")
            }

            if activeTab == .history && searchText.isEmpty && historyStore.entries.isEmpty == false {
                Button {
                    historyStore.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Clear History")
            }
        }
    }

    // MARK: - Helpers

    // True when any filter is active across notes or lists.
    private var isFilterActive: Bool {
        !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty
    }

    // Returns saved words filtered by active note and/or list selection.
    private var visibleWords: [SavedWord] {
        guard isFilterActive else { return wordsStore.words }
        return wordsStore.words.filter { word in
            let matchesNote = activeFilterNoteIDs.isEmpty || activeFilterNoteIDs.contains { word.sourceNoteIDs.contains($0) }
            let matchesList = activeFilterListIDs.isEmpty || activeFilterListIDs.contains { word.wordListIDs.contains($0) }
            return matchesNote && matchesList
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
