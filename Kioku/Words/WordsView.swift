import SwiftUI

// Renders the saved-word list screen for the Words tab.
// Major sections: filtered word list, toolbar (filter button), remove confirmation dialog.
struct WordsView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore

    @State private var selectedDetailWord: SavedWord?
    @State private var wordPendingRemoval: SavedWord?
    @State private var activeFilterListIDs: Set<UUID> = []
    @State private var isFilterPopoverPresented = false

    var body: some View {
        NavigationStack {
            List {
                if visibleWords.isEmpty {
                    Text("No saved words yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleWords, id: \.canonicalEntryID) { savedWord in
                        WordRowView(
                            word: savedWord,
                            lists: wordListsStore.lists,
                            onOpenDetails: { selectedDetailWord = savedWord },
                            onToggleList: { listID in wordsStore.toggleListMembership(wordID: savedWord.canonicalEntryID, listID: listID) },
                            onRemove: { wordPendingRemoval = savedWord }
                        )
                    }
                }
            }
            .toolbar {
                // Opens the filter popover for multi-select list filtering and list CRUD.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFilterPopoverPresented = true
                    } label: {
                        Image(systemName: activeFilterListIDs.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .popover(isPresented: $isFilterPopoverPresented) {
                        WordListFilterView(activeFilterListIDs: $activeFilterListIDs)
                            .environmentObject(wordListsStore)
                            .environmentObject(wordsStore)
                            .frame(minWidth: 300, minHeight: 400)
                    }
                }
            }
            // Confirmation before removing a word so accidental swipes can be cancelled.
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
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(item: $selectedDetailWord) { selectedWord in
            WordDetailView(word: selectedWord, lists: wordListsStore.lists)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // Applies the active list filter; shows all words when no filter is selected.
    private var visibleWords: [SavedWord] {
        let sorted = wordsStore.words.sorted { lhs, rhs in
            lhs.surface.localizedCaseInsensitiveCompare(rhs.surface) == .orderedAscending
        }

        guard !activeFilterListIDs.isEmpty else { return sorted }

        return sorted.filter { word in
            activeFilterListIDs.contains { word.wordListIDs.contains($0) }
        }
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
