import SwiftUI

// Renders the saved-word list screen for words starred from the read segment list.
struct WordsView: View {
    @State private var savedWords: [SavedWord] = []
    private let dictionaryStore = try? DictionaryStore()
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

    // Loads saved-word entries while migrating legacy plain-string storage values.
    private func loadSavedWordEntriesFromStorage() -> [SavedWord] {
        if let data = UserDefaults.standard.data(forKey: savedWordsStorageKey),
           let decodedEntries = try? JSONDecoder().decode([SavedWord].self, from: data) {
            return normalizedSavedWordEntries(decodedEntries)
        }

        if let data = UserDefaults.standard.data(forKey: savedWordsStorageKey),
           let legacyPayload = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var migratedEntries: [SavedWord] = []
            migratedEntries.reserveCapacity(legacyPayload.count)

            for item in legacyPayload {
                guard let surface = item["surface"] as? String,
                      let canonicalEntryID = resolveCanonicalEntryID(for: surface) else {
                    continue
                }

                let sourceNoteID: UUID?
                if let sourceNoteIDString = item["sourceNoteID"] as? String {
                    sourceNoteID = UUID(uuidString: sourceNoteIDString)
                } else {
                    sourceNoteID = nil
                }

                migratedEntries.append(
                    SavedWord(
                        canonicalEntryID: canonicalEntryID,
                        surface: normalizedSurfaceForStorage(surface),
                        sourceNoteID: sourceNoteID
                    )
                )
            }

            return normalizedSavedWordEntries(migratedEntries)
        }

        if let legacyWords = UserDefaults.standard.array(forKey: savedWordsStorageKey) as? [String] {
            let migratedEntries = legacyWords.compactMap { legacyWord -> SavedWord? in
                guard let canonicalEntryID = resolveCanonicalEntryID(for: legacyWord) else {
                    return nil
                }

                return SavedWord(
                    canonicalEntryID: canonicalEntryID,
                    surface: normalizedSurfaceForStorage(legacyWord),
                    sourceNoteID: nil
                )
            }

            return normalizedSavedWordEntries(migratedEntries)
        }

        return []
    }

    // Persists saved-word entries including optional source note references.
    private func persistSavedWordEntriesToStorage(_ entries: [SavedWord]) {
        if let encoded = try? JSONEncoder().encode(normalizedSavedWordEntries(entries)) {
            UserDefaults.standard.set(encoded, forKey: savedWordsStorageKey)
        }
    }

    // Resolves a saved-word surface into one canonical dictionary entry id.
    private func resolveCanonicalEntryID(for surface: String) -> Int64? {
        let normalizedSurface = normalizedSurfaceForStorage(surface)
        guard normalizedSurface.isEmpty == false,
              let dictionaryStore,
              let firstMatch = try? dictionaryStore.lookup(surface: normalizedSurface, mode: .kanjiAndKana).first
        else {
            return nil
        }

        return firstMatch.entryId
    }

    // Trims whitespace so persisted display surfaces stay stable across edits.
    private func normalizedSurfaceForStorage(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Coalesces duplicate saves by canonical entry id while preserving first-seen order.
    private func normalizedSavedWordEntries(_ entries: [SavedWord]) -> [SavedWord] {
        var mergedByEntryID: [Int64: SavedWord] = [:]
        var orderedEntryIDs: [Int64] = []

        for entry in entries {
            if var existing = mergedByEntryID[entry.canonicalEntryID] {
                let preferredSurface = existing.surface.isEmpty ? entry.surface : existing.surface
                let preferredSourceNoteID = existing.sourceNoteID ?? entry.sourceNoteID
                existing = SavedWord(
                    canonicalEntryID: existing.canonicalEntryID,
                    surface: preferredSurface,
                    sourceNoteID: preferredSourceNoteID
                )
                mergedByEntryID[entry.canonicalEntryID] = existing
                continue
            }

            mergedByEntryID[entry.canonicalEntryID] = entry
            orderedEntryIDs.append(entry.canonicalEntryID)
        }

        return orderedEntryIDs.compactMap { mergedByEntryID[$0] }
    }
}

#Preview {
    ContentView(selectedTab: .words)
}
