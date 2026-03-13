import SwiftUI

// Renders the saved-word list screen for words starred from the read segment list.
struct WordsView: View {
    @State private var savedWords: [SavedWord] = []
    private let savedWordsStorageKey = "kioku.words.v1"

    var body: some View {
        NavigationStack {
            // Displays the persisted saved-word entries and supports one-tap removal.
            List {
                if savedWords.isEmpty {
                    Text("No saved words yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedWords, id: \.canonicalEntryID) { savedWord in
                        HStack(spacing: 10) {
                            Text(savedWord.surface)
                                .font(.headline)

                            Spacer()

                            Button {
                                removeSavedWord(savedWord.canonicalEntryID)
                            } label: {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(Color.yellow)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Unsave Word")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .onAppear {
                // Loads persisted words when the tab becomes visible.
                refreshSavedWords()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                // Keeps the list synced when another screen updates saved words.
                refreshSavedWords()
            }
        }
        .toolbar(.visible, for: .tabBar)
    }

    // Loads and sorts saved words from shared persistent storage.
    private func refreshSavedWords() {
        savedWords = loadSavedWordEntriesFromStorage()
            .sorted { lhs, rhs in
                lhs.surface.localizedCaseInsensitiveCompare(rhs.surface) == .orderedAscending
            }
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
