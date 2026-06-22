import SwiftUI

// Presents dictionary entries at a chosen JLPT proficiency level (N5–N1), ordered by JPDB
// frequency within the level. Parallel to BrowseFrequencyView — owned by WordsView, presented as a
// sheet from the overflow menu. Levels are unofficial estimates (Tanos / Jonathan Waller, CC BY).
struct BrowseProficiencyView: View {
    let dictionaryStore: DictionaryStore?
    let isSaved: (Int64) -> Bool
    let onToggleSave: (DictionaryEntry) -> Void
    let onSelectEntry: (DictionaryEntry) -> Void

    @State private var entries: [DictionaryEntry] = []
    @State private var isLoading = true
    // Stored as the JLPT N-number: 5 = N5 (easiest) … 1 = N1 (hardest). Defaults to N5.
    @AppStorage("browseProficiency.level") private var level: Int = 5
    @Environment(\.dismiss) private var dismiss

    // Display order: easiest (N5) first.
    private let availableLevels = [5, 4, 3, 2, 1]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("JLPT N\(level)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(availableLevels, id: \.self) { value in
                                Button {
                                    level = value
                                    Task { await load() }
                                } label: {
                                    if value == level {
                                        Label("N\(value)", systemImage: "checkmark")
                                    } else {
                                        Text("N\(value)")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
        }
        .task { await load() }
    }

    // Either a loading spinner or the level's entries, ordered by frequency.
    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No proficiency data",
                systemImage: "graduationcap",
                description: Text("JLPT level data isn't available in the dictionary build.")
            )
        } else {
            List {
                // Unofficial-source disclaimer, kept lightweight as a section footer.
                Section {
                    ForEach(entries, id: \.entryId) { entry in
                        Button {
                            onSelectEntry(entry)
                        } label: {
                            DictionarySearchResultRow(
                                entry: entry,
                                isSaved: isSaved(entry.entryId),
                                onToggleSave: { onToggleSave(entry) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("\(entries.count) words · JLPT levels are unofficial estimates.")
                }
            }
            .listStyle(.plain)
        }
    }

    // Loads the level's entries off the main actor and swaps them in once ready.
    private func load() async {
        isLoading = true
        let currentLevel = level
        let store = dictionaryStore
        let loaded: [DictionaryEntry] = await Task.detached(priority: .userInitiated) {
            (try? store?.fetchEntriesByJLPT(level: currentLevel)) ?? []
        }.value
        entries = loaded
        isLoading = false
    }
}
