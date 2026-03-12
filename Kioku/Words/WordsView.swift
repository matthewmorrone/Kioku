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
                    ForEach(savedWords, id: \.surface) { savedWord in
                        HStack(spacing: 10) {
                            Text(savedWord.surface)
                                .font(.headline)

                            Spacer()

                            Button {
                                removeSavedWord(savedWord.surface)
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
    private func removeSavedWord(_ word: String) {
        var updatedWords = loadSavedWordEntriesFromStorage()
        updatedWords.removeAll { $0.surface == word }
        persistSavedWordEntriesToStorage(updatedWords)
        refreshSavedWords()
    }

    // Loads saved-word entries while migrating legacy plain-string storage values.
    private func loadSavedWordEntriesFromStorage() -> [SavedWord] {
        if let data = UserDefaults.standard.data(forKey: savedWordsStorageKey),
           let decodedEntries = try? JSONDecoder().decode([SavedWord].self, from: data) {
            return decodedEntries
        }

        if let legacyWords = UserDefaults.standard.array(forKey: savedWordsStorageKey) as? [String] {
            return legacyWords.map { legacyWord in
                SavedWord(surface: legacyWord, sourceNoteID: nil)
            }
        }

        return []
    }

    // Persists saved-word entries including optional source note references.
    private func persistSavedWordEntriesToStorage(_ entries: [SavedWord]) {
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: savedWordsStorageKey)
        }
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
