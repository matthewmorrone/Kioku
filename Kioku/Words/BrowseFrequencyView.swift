import SwiftUI

// Presents dictionary entries by frequency rank, loading the next page as the list scrolls
// to its end. Owned by WordsView; presented as a sheet from the overflow menu.
struct BrowseFrequencyView: View {
    let dictionaryStore: DictionaryStore?
    let isSaved: (Int64) -> Bool
    let onToggleSave: (DictionaryEntry) -> Void
    let onSelectEntry: (DictionaryEntry) -> Void

    @EnvironmentObject private var wordsStore: WordsStore
    @State private var entries: [DictionaryEntry] = []
    @State private var isLoading = true
    @State private var isLoadingPage = false
    @State private var hasMore = true
    @Environment(\.dismiss) private var dismiss

    private let pageSize = 100

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Browse Words")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .task { await loadNextPage() }
    }

    // Either a loading spinner or the ranked list with #rank prefixes.
    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No frequency data",
                systemImage: "chart.bar",
                description: Text("Frequency data isn't available in the dictionary build.")
            )
        } else {
            List {
                ForEach(Array(entries.enumerated()), id: \.element.entryId) { index, entry in
                    Button {
                        onSelectEntry(entry)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("#\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            DictionarySearchResultRow(
                                entry: entry,
                                isSaved: isSaved(entry.entryId),
                                onToggleSave: { onToggleSave(entry) },
                                learnedState: wordsStore.learnedState(for: entry.entryId),
                                onSetLearnedState: learnedStateSetter(
                                    entryID: entry.entryId,
                                    wordsStore: wordsStore,
                                    surface: entry.primarySearchSurface,
                                    defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
                                )
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if index == entries.count - 1 { Task { await loadNextPage() } }
                    }
                }
                if hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
    }

    // Appends the next page of ranked entries, fetched off the main actor. Called on appear and
    // whenever the last loaded row scrolls into view; the in-flight flag keeps pages from doubling up.
    private func loadNextPage() async {
        guard hasMore, isLoadingPage == false else { return }
        isLoadingPage = true
        let offset = entries.count
        let limit = pageSize
        let store = dictionaryStore
        let page: [DictionaryEntry] = await Task.detached(priority: .userInitiated) {
            (try? store?.fetchTopFrequencyEntries(limit: limit, offset: offset)) ?? []
        }.value
        entries.append(contentsOf: page)
        hasMore = page.count == limit
        isLoadingPage = false
        isLoading = false
    }
}
