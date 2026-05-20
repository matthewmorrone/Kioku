import SwiftUI

// Multi-radical kanji lookup grid. The user selects one or more radical components; the result
// list shows kanji that contain ALL of them. Radicals that can't co-occur with the current
// selection (no kanji contains all selected + this one) dim out, matching Nihongo's affordance.
// Owned by WordsView; presented as a sheet from the toolbar.
struct RadicalInputView: View {
    let dictionaryStore: DictionaryStore?
    let onSelectKanji: (String) -> Void

    @State private var allRadicals: [Radical] = []
    @State private var usableRadicals: Set<String> = []
    @State private var selected: [String] = []
    @State private var kanjiResults: [String] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    // Tap target sizing for the radical grid — keeps cells big enough for fingers on dense rows.
    private let radicalColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 7
    )

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Radicals")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    if selected.isEmpty == false {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Clear") {
                                selected = []
                                Task { await refresh() }
                            }
                        }
                    }
                }
                .task { await initialLoad() }
        }
    }

    // Either an empty/loading state, a "no data" state, or the radical grid + result row.
    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if allRadicals.isEmpty {
            ContentUnavailableView(
                "Radical data unavailable",
                systemImage: "square.grid.3x3",
                description: Text("Add RADKFILE2 and KRADFILE2 to Resources/ and rebuild the dictionary. See data_manifest.json for download instructions.")
            )
        } else {
            VStack(spacing: 0) {
                resultStrip
                Divider()
                radicalGrid
            }
        }
    }

    // Top strip: selected-radical chips on the left, scrolling kanji results to their right.
    @ViewBuilder
    private var resultStrip: some View {
        VStack(spacing: 8) {
            if selected.isEmpty == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selected, id: \.self) { glyph in
                            Button {
                                toggle(glyph)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(glyph).font(.title3)
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.accentColor.opacity(0.18))
                                )
                                .overlay(
                                    Capsule().stroke(Color.accentColor, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            if kanjiResults.isEmpty {
                Text(selected.isEmpty ? "Tap radicals below to start." : "No kanji contain all selected radicals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(kanjiResults, id: \.self) { kanji in
                            Button {
                                onSelectKanji(kanji)
                                dismiss()
                            } label: {
                                Text(kanji)
                                    .font(.title2)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(.tertiarySystemBackground))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    // Scrollable grid of radicals, grouped by stroke count with sticky section headers.
    @ViewBuilder
    private var radicalGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                let grouped = Dictionary(grouping: allRadicals, by: \.strokeCount)
                ForEach(grouped.keys.sorted(), id: \.self) { strokes in
                    Section {
                        LazyVGrid(columns: radicalColumns, spacing: 6) {
                            ForEach(grouped[strokes] ?? []) { radical in
                                radicalCell(radical)
                            }
                        }
                        .padding(.horizontal, 12)
                    } header: {
                        Text("\(strokes) stroke\(strokes == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground).opacity(0.95))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // One cell in the radical grid: selected → accented; unusable in current context → dimmed.
    @ViewBuilder
    private func radicalCell(_ radical: Radical) -> some View {
        let isSelected = selected.contains(radical.glyph)
        let isUsable = isSelected || usableRadicals.contains(radical.glyph)

        Button {
            toggle(radical.glyph)
        } label: {
            Text(radical.glyph)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.25)
                                : Color(.tertiarySystemBackground)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .opacity(isUsable ? 1.0 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(isUsable == false)
        .accessibilityLabel("Radical \(radical.glyph), \(radical.strokeCount) strokes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Selection updates

    // Toggles one radical in the selection and reruns the query for results + usability dimming.
    private func toggle(_ glyph: String) {
        if let idx = selected.firstIndex(of: glyph) {
            selected.remove(at: idx)
        } else {
            selected.append(glyph)
        }
        Task { await refresh() }
    }

    // First load: pull the radical inventory once, then run the initial empty-selection query.
    private func initialLoad() async {
        let store = dictionaryStore
        let radicals: [Radical] = await Task.detached(priority: .userInitiated) {
            (try? store?.fetchAllRadicals()) ?? []
        }.value
        allRadicals = radicals
        usableRadicals = Set(radicals.map(\.glyph))
        isLoading = false
    }

    // Recomputes the kanji result list AND the usable-radicals set whenever the selection changes.
    // Both queries dispatch off the main actor since they touch SQLite.
    private func refresh() async {
        let store = dictionaryStore
        let snapshot = selected
        async let kanjiTask = Task.detached(priority: .userInitiated) {
            (try? store?.fetchKanjiContainingAllRadicals(snapshot)) ?? []
        }.value
        async let usableTask = Task.detached(priority: .userInitiated) {
            (try? store?.fetchUsableRadicals(currentSelection: snapshot)) ?? []
        }.value
        let (kanji, usable) = await (kanjiTask, usableTask)

        // Drop the result if the selection changed underneath us mid-flight.
        guard snapshot == selected else { return }
        kanjiResults = kanji
        usableRadicals = usable
    }
}
