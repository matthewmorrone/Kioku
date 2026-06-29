import SwiftUI

// Presents the full KANJIDIC2 record for one kanji literal — every meaning, all readings,
// learner metadata, radical/frequency, and a list of common words containing this character.
// Owned by WordDetailView; presented as a sheet from a tap on the inline kanji row.
struct KanjiDetailView: View {
    let info: KanjiInfo
    let dictionaryStore: DictionaryStore?

    @State private var words: [DictionaryEntry] = []
    @State private var isLoadingWords = true
    @State private var strokes: [DictionaryStore.KanjiStrokeRecord] = []
    // Set when the user taps a common-word row; drives the nested WordDetailView sheet.
    // SavedWord is Identifiable by canonicalEntryID, so .sheet(item:) works directly on it.
    @State private var selectedCommonWord: SavedWord? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var savedKanjiStore: SavedKanjiStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    // Re-injected onto the nested WordDetailView sheet below so it always has the live store
    // even if env propagation through nested sheets ever drops it — matches the SegmentListView
    // pattern at the other call site that opens WordDetailView from a list.
    @EnvironmentObject private var wordsStore: WordsStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerCard
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // Zero out the List row's default top inset so the kanji animation sits
                        // flush against the nav bar; keep bottom inset so the chips don't bleed
                        // into the next section.
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                }
                // Section header padding above the FIRST section also gets removed — without
                // this, an InsetGrouped list still renders a ~22pt gap above the header card
                // regardless of the listRowInsets above.
                .listSectionSpacing(0)

                if info.meanings.isEmpty == false {
                    Section("Meanings") {
                        Text(info.meanings.joined(separator: ", "))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                if info.onReadings.isEmpty == false {
                    Section("On'yomi") {
                        // Display-time katakana→hiragana fold: KANJIDIC2 stores on'yomi as
                        // katakana (per dictionary convention), but the user prefers both on
                        // and kun readings shown in hiragana. The source data stays canonical;
                        // only the rendered string is folded. KanaNormalizer is the same helper
                        // used for furigana rendering of on'yomi.
                        readingChipFlow(info.onReadings.map(KanaNormalizer.katakanaToHiragana))
                    }
                }

                if info.kunReadings.isEmpty == false {
                    Section("Kun'yomi") {
                        // Kun'yomi often carries a `.` separating the kanji stem from the
                        // okurigana (e.g. た.べる) — kept verbatim in each chip because the
                        // dot is the actual learner-facing convention, not a decorator.
                        readingChipFlow(info.kunReadings)
                    }
                }

                Section("Common words") {
                    if isLoadingWords {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if words.isEmpty {
                        Text("No dictionary entries found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(words, id: \.entryId) { entry in
                            // Whole-row tap target — wrapping the row in a Button + .plain style
                            // keeps the visual layout identical while making the row activate the
                            // nested WordDetailView sheet. .contentShape ensures the empty space
                            // beside short glosses is hit-testable, not just the text glyphs.
                            Button {
                                selectedCommonWord = SavedWord.ephemeral(for: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.primarySearchSurface)
                                        .font(.body)
                                    if entry.primarySearchGloss.isEmpty == false {
                                        Text(entry.primarySearchGloss)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background {
                // Per-kanji ambient decoration fills the entire sheet behind the List.
                // .scrollContentBackground(.hidden) above lets the decoration show through
                // the list's default opaque background; rows keep their normal cards so
                // text stays readable while the decoration breathes through the gaps,
                // header card area (which has .listRowBackground(.clear)), and around
                // the navigation bar.
                KanjiDecoration.view(for: info.literal)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            // Nested WordDetail for a tapped common-word row. The presented SavedWord is
            // ephemeral (built via SavedWord.ephemeral(for:)); save / learned toggles in the
            // nested view still flow through WordsStore against the real canonicalEntryID, so
            // persisting from inside the nested view works the same as saving from a fresh open.
            // Mirrors the related-words nested-sheet pattern in WordDetailView.
            .sheet(item: $selectedCommonWord) { word in
                WordDetailView(
                    word: word,
                    reading: nil,
                    dictionaryStore: dictionaryStore,
                    segmenter: nil
                )
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .navigationTitle(info.literal)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Save / unsave toggle. Filled star = currently in SavedKanjiStore.
                    // Long-press surfaces a list-assignment menu so the user can drop the
                    // kanji into any of their lists in one step rather than save-then-edit.
                    let isSaved = savedKanjiStore.contains(literal: info.literal)
                    Button {
                        savedKanjiStore.toggle(literal: info.literal)
                    } label: {
                        Image(systemName: isSaved ? "star.fill" : "star")
                            .foregroundStyle(isSaved ? Color.yellow : Color.secondary)
                    }
                    .accessibilityLabel(isSaved ? "Remove from saved kanji" : "Save kanji")
                    .contextMenu { listAssignmentMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadWords() }
        }
    }

    // Context-menu content for the toolbar star: each user list gets a toggleable
    // row showing whether this kanji is currently a member. Saves the kanji first
    // if it isn't already saved — adding to a list always implies "yes, save this."
    @ViewBuilder
    private var listAssignmentMenu: some View {
        if wordListsStore.lists.isEmpty {
            Text("No lists yet — create one in Words")
        } else {
            let saved = savedKanjiStore.savedKanji(for: info.literal)
            let memberSet = Set(saved?.wordListIDs ?? [])
            ForEach(wordListsStore.lists) { list in
                Button {
                    if saved == nil {
                        savedKanjiStore.save(literal: info.literal, wordListIDs: [list.id])
                    } else {
                        savedKanjiStore.setListMembership(
                            literal: info.literal,
                            listID: list.id,
                            isMember: memberSet.contains(list.id) == false
                        )
                    }
                } label: {
                    if memberSet.contains(list.id) {
                        Label(list.name, systemImage: "checkmark")
                    } else {
                        Text(list.name)
                    }
                }
            }
        }
    }

    // Hero card: KanjiVG stroke-order animation when stroke data is available, falling back
    // to an oversized glyph. Metadata badges sit below either way. The per-kanji ambient
    // decoration (rain, fire, etc.) is rendered at sheet-background scope (.background on
    // the List above), not in the hero card itself.
    @ViewBuilder
    private var headerCard: some View {
        VStack(spacing: 12) {
            ZStack {
                if strokes.isEmpty {
                    Text(info.literal)
                        .font(.system(size: 96, weight: .regular))
                } else {
                    StrokeOrderAnimationView(strokes: strokes)
                        .frame(width: 180, height: 180)
                }
            }
            .frame(width: 180, height: 180)

            // Horizontal scroll so chips keep their natural width without internal text wrap
            // even when a kanji has all five badges populated (which can exceed screen width on
            // smaller phones). The chips themselves enforce lineLimit(1) + fixedSize, so even
            // inside an HStack they will never wrap; the scroller just keeps overflow reachable
            // rather than clipped.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let grade = info.grade {
                        metadataPill(grade == 8 ? "Secondary" : "Grade \(grade)")
                    }
                    if let jlpt = info.jlptLevel {
                        // "JLPT" prefix dropped — the N# notation is unambiguous on a kanji card.
                        metadataPill("N\(jlpt)")
                    }
                    if let strokes = info.strokeCount {
                        metadataPill("\(strokes) strokes")
                    }
                    if let radical = info.radical {
                        // "R" prefix kept (instead of bare number) so the chip can't be confused
                        // with stroke count when grade/JLPT are absent — radical numbers and
                        // stroke counts both live in roughly the same 1–214 range.
                        metadataPill("R\(radical)")
                    }
                    if let freq = info.freqMainichi {
                        // Ordinal form ("500th") reads as a rank without the literal word "Freq".
                        metadataPill(Self.ordinalString(freq))
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
        }
        // Only bottom padding here — top space removed per UX (kanji should sit flush at the
        // top of the sheet right under the nav bar).
        .padding(.bottom, 8)
    }

    // Pill styling for the metadata badges — matches the inline rows in WordDetailView.
    // lineLimit(1) + fixedSize keeps the chip text on a single line at its natural width:
    // chips never wrap internally and never compress to a narrower size that would force
    // truncation, even when the parent HStack is space-constrained.
    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
    }

    // Cached so the chip row doesn't allocate a new NumberFormatter per render. The ordinal
    // style produces locale-aware suffixes ("1st", "2nd", "500th" in English), so swapping the
    // user's locale just works without an English-only switch table here.
    private static let ordinalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    // Falls back to the plain integer string if the formatter unexpectedly returns nil — the
    // frequency pill is purely informational, so degrading to "500" beats hiding the badge.
    private static func ordinalString(_ n: Int) -> String {
        ordinalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // FlowLayout-wrapped chip row for on'yomi / kun'yomi readings. Each reading takes its
    // natural width and wraps to the next line, so a kanji with many readings (e.g. 生) lays
    // out as a tidy grid rather than a long ・-joined sentence. Enumerated id avoids any
    // collision risk if a reading were to repeat within a section.
    @ViewBuilder
    private func readingChipFlow(_ readings: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                readingChip(reading)
            }
        }
        .padding(.vertical, 4)
    }

    // Chip styling for an individual reading. Larger than the metadata pills above because
    // readings are primary content (the user needs to read the kana), not status badges.
    private func readingChip(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
    }

    // Loads up to 30 common words containing this kanji + the KanjiVG stroke data, both off the
    // main actor so the sheet's first frame doesn't block on SQL.
    private func loadWords() async {
        let literal = info.literal
        let store = dictionaryStore
        async let wordsTask = Task.detached(priority: .userInitiated) {
            (try? store?.searchEntriesContainingKanji(literal: literal, limit: 30)) ?? []
        }.value
        async let strokesTask = Task.detached(priority: .userInitiated) {
            (try? store?.fetchKanjiStrokes(for: literal)) ?? []
        }.value
        let (loadedWords, loadedStrokes) = await (wordsTask, strokesTask)
        words = loadedWords
        strokes = loadedStrokes
        isLoadingWords = false
    }
}
