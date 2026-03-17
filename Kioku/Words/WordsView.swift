import SwiftUI

// Renders the saved-word list screen for the Words tab.
// Major sections: word rows, toolbar (select-all, delete, edit, filter).
struct WordsView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var notesStore: NotesStore

    @State private var selectedDetailWord: SavedWord?
    @State private var wordPendingRemoval: SavedWord?
    @State private var activeFilterNoteIDs: Set<UUID> = []
    @State private var activeFilterListIDs: Set<UUID> = []
    @State private var isFilterSheetPresented = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedWordIDs: Set<Int64> = []
    @State private var isBatchRemoveConfirmPresented = false
    @State private var isBatchListSheetPresented = false

    var body: some View {
        NavigationStack {
            List(selection: $selectedWordIDs) {
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
                            onRemove: { wordPendingRemoval = savedWord }
                        )
                        .tag(savedWord.canonicalEntryID)
                    }
                    .onMove { fromOffsets, toOffset in
                        wordsStore.move(fromOffsets: fromOffsets, toOffset: toOffset)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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

                    // In edit mode with a selection opens batch list assignment; otherwise opens the filter sheet.
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
            }
            .confirmationDialog(
                "Remove \"\(wordPendingRemoval?.surface ?? "")\"?",
                isPresented: Binding(
                    get: { wordPendingRemoval != nil },
                    set: { if !$0 { wordPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let word = wordPendingRemoval {
                        wordsStore.remove(id: word.canonicalEntryID)
                    }
                    wordPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    wordPendingRemoval = nil
                }
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
        .sheet(item: $selectedDetailWord) { selectedWord in
            WordDetailView(word: selectedWord, lists: wordListsStore.lists)
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
    }

    // True when any filter is active across notes or lists.
    private var isFilterActive: Bool {
        !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty
    }

    // Returns words in store order filtered by active note and/or list selection.
    // When both note and list filters are active, a word must match at least one from each group.
    private var visibleWords: [SavedWord] {
        guard isFilterActive else { return wordsStore.words }

        return wordsStore.words.filter { word in
            let matchesNote = activeFilterNoteIDs.isEmpty || activeFilterNoteIDs.contains { word.sourceNoteIDs.contains($0) }
            let matchesList = activeFilterListIDs.isEmpty || activeFilterListIDs.contains { word.wordListIDs.contains($0) }
            return matchesNote && matchesList
        }
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
