import SwiftUI

// Presents the top dictionary entries by JPDB frequency rank, paged by user-selected bucket size.
// Owned by WordsView; presented as a sheet from the toolbar.
struct BrowseFrequencyView: View {
    let dictionaryStore: DictionaryStore?
    let isSaved: (Int64) -> Bool
    let onToggleSave: (DictionaryEntry) -> Void
    let onSelectEntry: (DictionaryEntry) -> Void

    @State private var entries: [DictionaryEntry] = []
    @State private var isLoading = true
    @AppStorage("browseFrequency.limit") private var limit: Int = 1000
    @Environment(\.dismiss) private var dismiss

    private let availableLimits = [100, 500, 1000, 2500, 5000]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Top \(limit)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(availableLimits, id: \.self) { value in
                                Button {
                                    limit = value
                                    Task { await load() }
                                } label: {
                                    if value == limit {
                                        Label("Top \(value)", systemImage: "checkmark")
                                    } else {
                                        Text("Top \(value)")
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
                                onToggleSave: { onToggleSave(entry) }
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
    }

    // Loads the top-N entries off the main actor and swaps them in once ready.
    private func load() async {
        isLoading = true
        let currentLimit = limit
        let store = dictionaryStore
        let loaded: [DictionaryEntry] = await Task.detached(priority: .userInitiated) {
            (try? store?.fetchTopFrequencyEntries(limit: currentLimit)) ?? []
        }.value
        entries = loaded
        isLoading = false
    }
}
