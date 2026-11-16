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
                            }
                        }
                        .opacity(matches(result) ? 1 : 0.35)
                    }
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
        guard trimmed.isEmpty == false, isSearching == false else { return }
        isSearching = true
        statusText = "Searching…"
        defer { isSearching = false }
        do {
            results = try await YouTubeSearch.search(query: trimmed)
            statusText = results.isEmpty ? "No videos found." : ""
        } catch {
            AppLog.error(.audioAlignment, "youtube search failed — \(error.localizedDescription)")
            results = []
            statusText = "Search failed: \(error.localizedDescription)"
        }
    }
}
