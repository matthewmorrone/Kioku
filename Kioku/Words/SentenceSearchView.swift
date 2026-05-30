import SwiftUI

// Free-form sentence search across the Tatoeba corpus. Distinct from per-entry sentence display:
// the user enters any phrase (Japanese or English) and sees matching sentence pairs.
// Owned by WordsView; presented as a sheet from the toolbar.
struct SentenceSearchView: View {
    let dictionaryStore: DictionaryStore?

    @State private var query: String = ""
    @State private var results: [SentencePair] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sentences")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the Tatoeba corpus…")
                .textInputAutocapitalization(.never)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(for: newValue)
                }
        }
    }

    // Empty state, spinner, "no matches" state, or the results list — picked by the current query/results.
    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search example sentences",
                systemImage: "text.bubble",
                description: Text("Type any Japanese or English phrase to find sentences from the Tatoeba corpus.")
            )
        } else if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(Array(results.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 6) {
                    Text(pair.japanese)
                        .font(.body)
                    Text(pair.english)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .textSelection(.enabled)
            }
            .listStyle(.plain)
        }
    }

    // Debounces the FTS5 query so quick typing doesn't fire one search per keystroke.
    private func scheduleSearch(for input: String) {
        searchTask?.cancel()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            results = []
            isLoading = false
            return
        }

        isLoading = true
        let store = dictionaryStore
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }

            let loaded: [SentencePair] = await Task.detached(priority: .userInitiated) {
                (try? store?.searchSentences(query: trimmed)) ?? []
            }.value

            guard Task.isCancelled == false,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

            results = loaded
            isLoading = false
        }
    }
}
