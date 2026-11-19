import SwiftUI

// Sheet for finding a YouTube video by song name. Renders a search field (pre-filled with the
// note's title), then a list of results — thumbnail, title, channel, length — and reports the
// tapped video's id. Sections: search bar, status line (loading/empty/error), result list.
struct YouTubeSearchSheet: View {
    @State var query: String
    // The open note's audio length in seconds, when it has audio; results of a different length are dimmed.
    var referenceSeconds: Double? = nil
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var results: [YouTubeSearchResult] = []
    @State private var isSearching = false
    @State private var statusText = ""
    // The token for the next page of results, nil once they run out, and a guard against two loads at once.
    @State private var continuation: String?
    @State private var isLoadingMore = false

    var body: some View {
        NavigationStack {
            List {
                if statusText.isEmpty == false {
                    Text(statusText).foregroundStyle(.secondary)
                }
                ForEach(results) { result in
                    Button { onSelect(result.videoID) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: result.thumbnailURL) { image in
                                image.resizable().aspectRatio(16 / 9, contentMode: .fill)
                            } placeholder: {
                                Color.secondary.opacity(0.2)
                            }
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                                Text([result.channel, result.duration].filter { $0.isEmpty == false }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                Label(result.hasSubtitles ? "Subtitles" : "No subtitles", systemImage: result.hasSubtitles ? "captions.bubble.fill" : "captions.bubble")
                                    .font(.caption2)
                                    .foregroundStyle(result.hasSubtitles ? Color.accentColor : Color.secondary)
                            }
                        }
                        .opacity(matches(result) ? 1 : 0.35)
                    }
                    // Reaching the last result loads the next page, so the list keeps going as you scroll.
                    .onAppear { if result.id == results.last?.id { Task { await loadMore() } } }
                }
                if continuation != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .onSubmit(of: .search) { Task { await runSearch() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
        .task { await runSearch() }
    }

    // Whether a result is about as long as the note's audio, within the 3 s the player tolerates. With
    // no audio to compare against, or no length shown, every result counts as a match.
    private func matches(_ result: YouTubeSearchResult) -> Bool {
        guard let reference = referenceSeconds, reference > 0, let length = result.durationSeconds else { return true }
        return abs(length - reference) <= 3
    }

    // Runs the current query and shows its results, or a short reason when there are none.
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            statusText = "Type a song name to search."
            return
        }
        guard isSearching == false else { return }
        isSearching = true
        statusText = "Searching…"
        defer { isSearching = false }
        do {
            let page = try await YouTubeSearch.search(query: trimmed)
            results = page.results
            continuation = page.continuation
            statusText = results.isEmpty ? "No videos found." : ""
        } catch {
            AppLog.error(.audioAlignment, "youtube search failed — \(error.localizedDescription)")
            results = []
            continuation = nil
            statusText = "Search failed: \(error.localizedDescription)"
        }
    }

    // Appends the next page of the current search, skipping videos already listed. A failure is
    // logged and ends the paging, leaving what is already shown.
    private func loadMore() async {
        guard let token = continuation, isLoadingMore == false, isSearching == false else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await YouTubeSearch.search(query: query, continuation: token)
            let known = Set(results.map(\.id))
            results.append(contentsOf: page.results.filter { known.contains($0.id) == false })
            continuation = page.results.isEmpty ? nil : page.continuation
        } catch {
            AppLog.error(.audioAlignment, "youtube search paging failed — \(error.localizedDescription)")
            continuation = nil
        }
    }
}
