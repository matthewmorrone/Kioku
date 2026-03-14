import SwiftUI

// Renders the saved-word list screen for words starred from the read segment list.
struct WordsView: View {
    @EnvironmentObject private var notesStore: NotesStore
    @State private var savedWords: [SavedWord] = []
    @State private var selectedDetailWord: SavedWord?
    private let savedWordsStorageKey = "kioku.words.v1"

    var body: some View {
        NavigationStack {
            // Displays saved words as a flat list with right-side membership labels.
            List {
                if savedWords.isEmpty {
                    Text("No saved words yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedSavedWords, id: \.canonicalEntryID) { savedWord in
                        HStack(spacing: 10) {
                            Text(savedWord.surface)
                                .font(.headline)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openWordDetail(for: savedWord)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeSavedWord(savedWord.canonicalEntryID)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .onAppear {
                // Loads persisted words when the tab becomes visible.
                refreshSavedWords()
            }
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(item: $selectedDetailWord) { selectedWord in
            WordDetailView(
                word: selectedWord,
                membershipTitles: membershipTitles(for: selectedWord)
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // Provides note titles keyed by note id for list-membership labeling.
    private var noteTitleByID: [UUID: String] {
        Dictionary(uniqueKeysWithValues: notesStore.notes.map { note in
            (note.id, normalizedListTitle(for: note.title))
        })
    }

    // Keeps the visible words list stable and alphabetically ordered.
    private var sortedSavedWords: [SavedWord] {
        savedWords.sorted { lhs, rhs in
            lhs.surface.localizedCaseInsensitiveCompare(rhs.surface) == .orderedAscending
        }
    }

    // Resolves all list titles that include one saved word.
    private func membershipTitles(for savedWord: SavedWord) -> [String] {
        if savedWord.sourceNoteIDs.isEmpty {
            return ["Unsorted"]
        }

        let titles = savedWord.sourceNoteIDs.map { sourceNoteID in
            noteTitleByID[sourceNoteID] ?? "Deleted Note"
        }

        let uniqueTitles = Array(Set(titles))
        let fixedOrder: [String] = ["Unsorted", "Deleted Note"]
        let regularTitles = uniqueTitles
            .filter { fixedOrder.contains($0) == false }
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }

        let trailingTitles = fixedOrder.filter { uniqueTitles.contains($0) }
        return regularTitles + trailingTitles
    }

    // Opens the full-screen word detail sheet with list-membership context for one row.
    private func openWordDetail(for savedWord: SavedWord) {
        selectedDetailWord = savedWord
    }

    // Normalizes a note title into a stable list name and falls back when title is empty.
    private func normalizedListTitle(for title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Untitled Note" : trimmedTitle
    }

    // Loads and sorts saved words from shared persistent storage.
    private func refreshSavedWords() {
        savedWords = loadSavedWordEntriesFromStorage()
    }

    // Removes a single saved word and persists the updated list.
    private func removeSavedWord(_ canonicalEntryID: Int64) {
        var updatedWords = loadSavedWordEntriesFromStorage()
        updatedWords.removeAll { $0.canonicalEntryID == canonicalEntryID }
        persistSavedWordEntriesToStorage(updatedWords)
        refreshSavedWords()
    }

    // Loads canonical saved-word entries from shared storage.
    private func loadSavedWordEntriesFromStorage() -> [SavedWord] {
        SavedWordStorageMigrator.loadSavedWords(storageKey: savedWordsStorageKey)
    }

    // Persists saved-word entries including optional source note references.
    private func persistSavedWordEntriesToStorage(_ entries: [SavedWord]) {
        SavedWordStorageMigrator.persist(entries: entries, storageKey: savedWordsStorageKey)
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
