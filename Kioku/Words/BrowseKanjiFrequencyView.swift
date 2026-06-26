import SwiftUI

// Presents the top KANJIDIC2 kanji by Mainichi-newspaper frequency rank, paged
// by user-selected bucket size. Owned by WordsView; presented as a sheet from
// the overflow menu's "Browse Kanji by Frequency" entry. Mirrors
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
    @AppStorage("browseKanjiFrequency.limit") private var limit: Int = 500
    @Environment(\.dismiss) private var dismiss

    private let availableLimits = [100, 250, 500, 1000, 2500]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Top \(limit) Kanji")
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
                .sheet(item: $presentedKanjiInfo) { info in
                    KanjiDetailView(info: info, dictionaryStore: dictionaryStore)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
        .task { await load() }
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
                    .font(.system(size: 18, weight: .semibold))
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

    // Loads the top-N kanji off the main actor and swaps them in once ready.
    private func load() async {
        isLoading = true
        let currentLimit = limit
        let store = dictionaryStore
        let loaded: [KanjiInfo] = await Task.detached(priority: .userInitiated) {
            (try? store?.fetchTopFrequencyKanji(limit: currentLimit)) ?? []
        }.value
        kanji = loaded
        isLoading = false
    }
}
