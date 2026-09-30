import SwiftUI

// Presents KANJIDIC2 kanji by Mainichi-newspaper frequency rank, loading the
// next page as the list scrolls to its end. Owned by WordsView; presented as a
// sheet from the overflow menu's "Browse Kanji" entry. Mirrors
// BrowseFrequencyView for words but renders kanji tiles instead of word rows
// and routes taps to KanjiDetailView via `onSelectKanji`.
struct BrowseKanjiFrequencyView: View {
    let dictionaryStore: DictionaryStore?
    let isSaved: (String) -> Bool
    let onToggleSave: (KanjiInfo) -> Void

    @State private var kanji: [KanjiInfo] = []
    @State private var isLoading = true
    // Presents KanjiDetailView as a SECOND sheet stacked on top of this one, so
    // dismissing the kanji detail returns the user to the browse list rather
    // than collapsing the whole sheet stack back to the Words tab.
    @State private var presentedKanjiInfo: KanjiInfo? = nil
    @State private var isLoadingPage = false
    @State private var hasMore = true
    @Environment(\.dismiss) private var dismiss

    private let pageSize = 100

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Browse Kanji")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
                .sheet(item: $presentedKanjiInfo) { info in
                    KanjiDetailView(info: info, dictionaryStore: dictionaryStore)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
        .task { await loadNextPage() }
    }

    // Loading spinner, empty state, or the ranked kanji list with #rank prefixes.
    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kanji.isEmpty {
            ContentUnavailableView(
                "No frequency data",
                systemImage: "chart.bar",
                description: Text("Kanji frequency data isn't available in the dictionary build.")
            )
        } else {
            List {
                ForEach(Array(kanji.enumerated()), id: \.element.literal) { index, info in
                    Button {
                        presentedKanjiInfo = info
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text("#\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            kanjiRow(info)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if index == kanji.count - 1 { Task { await loadNextPage() } }
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

    // One row: kanji glyph in a tinted tile + meanings + grade/JLPT/stroke pills
    // + a trailing star toggle. Visually matches the kanji-result row shape in
    // the search results section so the user reads them as the same kind of object.
    @ViewBuilder
    private func kanjiRow(_ info: KanjiInfo) -> some View {
        let saved = isSaved(info.literal)
        HStack(alignment: .center, spacing: 12) {
            Text(info.literal)
                .font(.system(size: 32, weight: .medium))
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                if info.meanings.isEmpty == false {
                    Text(info.meanings.prefix(3).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let grade = info.grade {
                        kanjiMetaPill(grade == 8 ? "Secondary" : "Grade \(grade)")
                    }
                    if let jlpt = info.jlptLevel {
                        kanjiMetaPill("JLPT N\(jlpt)")
                    }
                    if let strokes = info.strokeCount {
                        kanjiMetaPill("\(strokes) strokes")
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                onToggleSave(info)
            } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? Color.yellow : Color.secondary)
                    .scaledFont(size: 18, weight: .semibold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(saved ? "Remove from saved kanji" : "Save kanji")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // Pill chip for grade / JLPT / stroke metadata — kept local so the styling
    // stays in sync with the search-result kanji rows.
    @ViewBuilder
    private func kanjiMetaPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.15))
            )
    }

    // Appends the next page of ranked kanji, fetched off the main actor. Called on appear and
    // whenever the last loaded row scrolls into view; the in-flight flag keeps pages from doubling up.
    private func loadNextPage() async {
        guard hasMore, isLoadingPage == false else { return }
        isLoadingPage = true
        let offset = kanji.count
        let limit = pageSize
        let store = dictionaryStore
        let page: [KanjiInfo] = await Task.detached(priority: .userInitiated) {
            (try? store?.fetchTopFrequencyKanji(limit: limit, offset: offset)) ?? []
        }.value
        kanji.append(contentsOf: page)
        hasMore = page.count == limit
        isLoadingPage = false
        isLoading = false
    }
}
