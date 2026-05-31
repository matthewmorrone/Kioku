import SwiftUI

// Tabs available in the Words screen.
enum WordsTab { case saved, history }

// Sort options for both saved words and history.
enum WordsSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case aToZ
    case zToA

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        case .aToZ: "A to Z"
        case .zToA: "Z to A"
        }
    }
}

// Cross-tab routing for the Words screen.
enum WordsRoute: Equatable {
    case detail(entryID: Int64, surface: String?, reading: String? = nil, sublatticePaths: [[String]] = [])
    case search(String)
}

// Renders the saved-word list screen for the Words tab.
// Major sections: search bar, saved/history tab picker, word rows, toolbar.
struct WordsView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Receives cross-tab routing requests from ContentView.
    var pendingRoute: Binding<WordsRoute?> = .constant(nil)

    @EnvironmentObject var wordsStore: WordsStore
    @EnvironmentObject var wordListsStore: WordListsStore
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var historyStore: HistoryStore

    @State var selectedDetailWord: SavedWord?
    // Reading that was active in the lookup sheet when this word detail was opened, if available.
    @State var selectedDetailReading: String?
    @State var selectedDetailSublatticePaths: [[String]] = []
    @State var activeFilterNoteIDs: Set<UUID> = []
    @State var activeFilterListIDs: Set<UUID> = []
    @State var isFilterSheetPresented = false
    // Drives the "Choose Lemma…" disambiguation sheet for saved-word and history rows.
    @State var lemmaPickerContext: WordsLemmaPickerContext?
    @State var editMode: EditMode = .inactive
    @State var selectedWordIDs: Set<Int64> = []
    @State var isBatchRemoveConfirmPresented = false
    @State var isBatchRemoveHistoryConfirmPresented = false
    @State var isBatchListSheetPresented = false
    @State var isCSVImportPresented = false
    @State var isBrowseFrequencyPresented = false
    @State var isSentenceSearchPresented = false
    @State var isRadicalInputPresented = false
    @State var isHandwritingPresented = false
    @State var activeTab: WordsTab = .history
    @AppStorage("savedWordsSortOrder") var savedSortOrder: String = WordsSortOrder.newestFirst.rawValue
    @AppStorage("historySortOrder") var historySortOrderRaw: String = WordsSortOrder.newestFirst.rawValue
    @State var searchText = ""
    @State var convertedKana: String? = nil
    @State var searchMode: DictionarySearchMode = .japanese
    @State var searchSortMode: DictionarySearchSortMode = .relevance
    @State var searchCommonWordsOnly = false
    @State var searchSelectedPartsOfSpeech: Set<String> = []

    var savedSort: WordsSortOrder { WordsSortOrder(rawValue: savedSortOrder) ?? .newestFirst }
    var historySort: WordsSortOrder { WordsSortOrder(rawValue: historySortOrderRaw) ?? .newestFirst }
    @State var searchResults: [DictionaryEntry] = []
    // Populated when the query segments into multiple tokens — switches the search results
    // view from entry-list mode to one-row-per-segment mode (Pleco-style sentence parse).
    @State var parsedSegments: [ParsedSegment] = []
    @State var searchTask: Task<Void, Never>?
    // Surfaced as a red banner over the results list when either dictionary search mode
    // throws. Defaults to nil; populated only after a failed search task.
    @State var searchError: String?
    // True while a search task is running (debounce sleep + SQL fan-out). Drives the
    // spinner in searchEmptyOverlay so "results pending" can't be mistaken for "no hits."
    @State var isSearching = false
    // Controls keyboard focus on the custom search field. Toggled programmatically by
    // the background tap-to-dismiss handler so we don't depend on .searchable's auto-
    // injected Cancel button.
    @FocusState var isSearchFieldFocused: Bool
    // Materialized dictionary entries keyed by canonical entry id, populated on view
    // appear and whenever the history list grows. Lets historyContent reuse the
    // entryRow layout (kanji+reading+gloss+star) without per-row SQL.
    @State var materializedHistory: [Int64: DictionaryEntry] = [:]

    // Builds the word model used by WordDetailView, reusing a saved word when available and
    // otherwise synthesizing a temporary detail target from the route payload or dictionary entry.
    func detailWord(entryID: Int64, surfaceHint: String?) -> SavedWord? {
        if let saved = wordsStore.words.first(where: { $0.canonicalEntryID == entryID }) {
            return saved
        }

        if let surfaceHint, surfaceHint.isEmpty == false {
            return SavedWord(canonicalEntryID: entryID, surface: surfaceHint)
        }

        guard let entry = try? dictionaryStore?.lookupEntry(entryID: entryID) else {
            return nil
        }

        // matchedSurface reflects how the entry was reached, so prefer it over kanjiForms.first
        // which would otherwise promote kana-routed lookups to kanji.
        let surface = entry.matchedSurface.isEmpty == false
            ? entry.matchedSurface
            : (entry.kanaForms.first?.text ?? entry.kanjiForms.first?.text ?? "")

        guard surface.isEmpty == false else { return nil }
        return SavedWord(canonicalEntryID: entryID, surface: surface)
    }

    // Applies a cross-tab route, either by opening a word detail or populating the search query.
    private func consumePendingRoute(_ route: WordsRoute?) {
        guard let route else { return }

        switch route {
        case let .detail(entryID, surface, reading, sublatticePaths):
            if let word = detailWord(entryID: entryID, surfaceHint: surface) {
                activeTab = .saved
                selectedDetailWord = word
                selectedDetailReading = reading
                selectedDetailSublatticePaths = sublatticePaths
            }

        case let .search(query):
            activeTab = .saved
            selectedDetailWord = nil
            editMode = .inactive
            selectedWordIDs.removeAll()
            searchText = query
        }

        pendingRoute.wrappedValue = nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                customSearchBar
                resultsList
            }
            .sheet(item: $selectedDetailWord) { word in
                WordDetailView(
                    word: word,
                    reading: selectedDetailReading,
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    initialSublatticePaths: selectedDetailSublatticePaths
                )
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isBatchListSheetPresented) {
                // Pass the active list filter as the Move source only when exactly one list
                // is filtered — that's the single unambiguous "list you're viewing".
                WordsBatchListView(
                    selectedWordIDs: selectedWordIDs,
                    sourceListID: activeFilterListIDs.count == 1 ? activeFilterListIDs.first : nil,
                    surfaces: selectionSurfaces
                )
                    .environmentObject(wordsStore)
                    .environmentObject(wordListsStore)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Remove \(selectedWordIDs.count) word\(selectedWordIDs.count == 1 ? "" : "s")?",
                isPresented: $isBatchRemoveConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    wordsStore.remove(ids: selectedWordIDs)
                    selectedWordIDs.removeAll()
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $isCSVImportPresented) {
                CSVImportView(dictionaryStore: dictionaryStore)
                    .environmentObject(wordsStore)
                    .environmentObject(wordListsStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
            }
            .sheet(isPresented: $isHandwritingPresented) {
                HandwritingInputView(onSelectCharacter: handleHandwritingSelect)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isBrowseFrequencyPresented) {
                BrowseFrequencyView(
                    dictionaryStore: dictionaryStore,
                    isSaved: { entryID in wordsStore.words.contains(where: { $0.canonicalEntryID == entryID }) },
                    onToggleSave: handleBrowseToggleSave,
                    onSelectEntry: handleBrowseSelectEntry
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isSentenceSearchPresented) {
                SentenceSearchView(dictionaryStore: dictionaryStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isRadicalInputPresented) {
                RadicalInputView(
                    dictionaryStore: dictionaryStore,
                    onSelectKanji: handleRadicalSelectKanji
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                WordsFilterView(
                    activeFilterNoteIDs: $activeFilterNoteIDs,
                    activeFilterListIDs: $activeFilterListIDs,
                    showSavedWords: Binding(
                        get: { activeTab == .saved },
                        set: { activeTab = $0 ? .saved : .history }
                    ),
                    // Sort writes to whichever list is currently visible — saved vs history
                    // have separate persisted AppStorage keys but the user only sees one
                    // sort menu at a time, so we delegate based on activeTab.
                    sortOrder: Binding(
                        get: {
                            activeTab == .saved ? savedSort : historySort
                        },
                        set: { newValue in
                            if activeTab == .saved {
                                savedSortOrder = newValue.rawValue
                            } else {
                                historySortOrderRaw = newValue.rawValue
                            }
                        }
                    )
                )
                .environmentObject(wordListsStore)
                .environmentObject(wordsStore)
                .environmentObject(notesStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $lemmaPickerContext) { context in
                LemmaPickerSheet(
                    surface: context.surface,
                    candidates: context.candidates,
                    dictionaryStore: dictionaryStore,
                    onChoose: { lemma, canonicalEntryID in
                        context.onChoose(lemma, canonicalEntryID)
                        lemmaPickerContext = nil
                    },
                    onCancel: { lemmaPickerContext = nil }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: searchText) { _, newValue in
                runDictionarySearch(query: newValue)
            }
            .task(id: dictionaryStore != nil) {
                if dictionaryStore != nil, searchText.isEmpty == false {
                    runDictionarySearch(query: searchText)
                }
                refreshMaterializedHistory()
            }
            .onChange(of: historyStore.entries.map(\.id)) { _, _ in
                refreshMaterializedHistory()
            }
            .onChange(of: wordsStore.words.map(\.canonicalEntryID)) { _, _ in
                refreshMaterializedHistory()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // Custom search field. Replaces `.searchable` so we own the chrome end-to-end and
    // don't get the iOS auto-injected Cancel button sitting beside the field.
    private var customSearchBar: some View {
        HStack(spacing: 8) {
            // Overflow menu to the left of the search bar — houses actions that aren't
            // primary navigation (Edit mode, CSV import) so they don't crowd the bar
            // itself. ellipsis.circle is the system idiom for "more actions here".
            Menu {
                Button {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode == .inactive { selectedWordIDs.removeAll() }
                } label: {
                    Label(editMode == .active ? "Done Editing" : "Edit",
                          systemImage: editMode == .active ? "checkmark.circle" : "pencil")
                }
                Button {
                    isCSVImportPresented = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                // One selection menu for every tab. Because every word row selects into the
                // same selectedWordIDs set, Select All and Manage Lists are identical code on
                // Saved and History. Only the destructive verb differs — "Remove" means unsave
                // on Saved and delete-from-log on History — so just that one action is
                // contextual; everything else is genuinely shared.
                if editMode == .active {
                    Divider()
                    let selectable = selectableWordIDs
                    Button {
                        if selectedWordIDs.count == selectable.count {
                            selectedWordIDs.removeAll()
                        } else {
                            selectedWordIDs = Set(selectable)
                        }
                    } label: {
                        if selectedWordIDs.count == selectable.count && selectable.isEmpty == false {
                            Label("Deselect All", systemImage: "minus.circle")
                        } else {
                            Label("Select All", systemImage: "circle.dashed.inset.filled")
                        }
                    }
                    .disabled(selectable.isEmpty)

                    if selectedWordIDs.isEmpty == false {
                        Button {
                            isBatchListSheetPresented = true
                        } label: {
                            Label("Manage Lists…", systemImage: "text.badge.plus")
                        }
                        Button(role: .destructive) {
                            if activeTab == .history {
                                historyStore.remove(canonicalEntryIDs: selectedWordIDs)
                                selectedWordIDs.removeAll()
                                editMode = .inactive
                            } else {
                                isBatchRemoveConfirmPresented = true
                            }
                        } label: {
                            Label(activeTab == .history
                                  ? "Remove from History (\(selectedWordIDs.count))"
                                  : "Remove from Saved (\(selectedWordIDs.count))",
                                  systemImage: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: editMode == .active ? "checkmark.circle.fill" : "ellipsis.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(editMode == .active ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel("More actions")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Japanese or English", text: $searchText)
                    .focused($isSearchFieldFocused)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        // Explicit Return/Search records the phrase as a .query history
                        // entry. HistoryStore.record(query:) handles dedup + bump-to-top.
                        historyStore.record(query: searchText)
                    }
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())

            // Filter sheet entrypoint sits outside the search capsule so the active-filter
            // pill-fill state reads as separate UI. Icon flips to its filled variant when
            // any note/list filter is on.
            Button {
                isFilterSheetPresented = true
            } label: {
                Image(systemName: isFilterActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isFilterActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter by Note or List")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var resultsList: some View {
        // ONE selection model for every word row, whichever tab it lives on: a word is
        // identified by its canonical entry id (Int64), so Saved, History, and search-result
        // rows all select into the same selectedWordIDs set. That's what lets the batch menu
        // be a single shared interface instead of per-tab silos. History `.query` rows (free-
        // text searches with no word behind them) carry no Int64 tag, so they're simply not
        // selectable — which is correct, you can't add a search phrase to a list.
        List(selection: $selectedWordIDs) {
            if searchText.isEmpty && activeTab == .saved {
                // Saved tab: all favorites (filtered by note/list when filters are on).
                // filteredSavedContent uses visibleWords which already applies the filter,
                // so this same view works for both the unfiltered "show all" and narrowed cases.
                filteredSavedContent
            } else if searchText.isEmpty && activeTab == .history {
                // History tab: lookup log, newest first.
                historyContent
            } else if parsedSegments.isEmpty == false {
                // Sentence-parse mode: query produced ≥2 tokens via MeCab, so render
                // one row per token rather than chasing a literal dictionary lookup.
                parsedSegmentsResultsSection
            } else {
                ForEach(searchResults, id: \.entryId) { entry in
                    wordRow(
                        entryID: entry.entryId,
                        surface: entry.primarySearchSurface,
                        entry: entry,
                        gloss: matchingGloss(for: entry, query: searchText),
                        onTap: {
                            isSearchFieldFocused = false
                            openSearchResult(entry)
                        }
                    )
                }
            }
        }
        .listStyle(.plain)
        // Edit-mode binding so List(selection:) shows the selection circles on every tab.
        .environment(\.editMode, $editMode)
        // Dismiss the keyboard the moment the user scrolls (system iOS behaviour)
        // and on any tap landing on empty space (via the background overlay below).
        .scrollDismissesKeyboard(.immediately)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    isSearchFieldFocused = false
                }
        }
        .overlay { searchEmptyOverlay }
        .overlay(alignment: .top) {
            if let searchError {
                Text("Search failed: \(searchError)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

    // Placeholder when no query (or the query produced nothing), or a spinner if the
    // dictionary store hasn't published yet so the user knows we're not ignoring them.
    @ViewBuilder
    private var searchEmptyOverlay: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if dictionaryStore == nil {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Loading dictionary…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if trimmed.isEmpty {
            // The list shows history when the query is empty — let it render through;
            // historyContent draws its own "No lookup history yet" placeholder for the
            // truly-empty case so we don't need a wrapper here.
            EmptyView()
        } else if isSearching {
            ProgressView().controlSize(.large)
        } else if searchResults.isEmpty && parsedSegments.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        }
    }

    // Batch-materializes all .entry-kind history rows AND saved-words rows so the
    // unified entryRow can render them with the same kanji+reading+gloss+star layout
    // as search results. One SQL roundtrip total — re-runs whenever the history set
    // or the saved-words set changes.
    func refreshMaterializedHistory() {
        guard let store = dictionaryStore else { return }
        let historyIDs = historyStore.entries
            .filter { $0.kind == .entry }
            .map(\.canonicalEntryID)
        let savedIDs = wordsStore.words.map(\.canonicalEntryID)
        let neededIDs = Array(Set(historyIDs + savedIDs))
        let missing = neededIDs.filter { materializedHistory[$0] == nil }
        guard missing.isEmpty == false else { return }
        Task.detached(priority: .userInitiated) {
            let entries = (try? store.lookupEntries(entryIDs: missing)) ?? []
            await MainActor.run {
                for entry in entries {
                    materializedHistory[entry.entryId] = entry
                }
            }
        }
    }

    // Picks the gloss to display for a result row. Walks senses in their canonical
    // order_index order and returns the first gloss whose text (case-folded) contains
    // the search term — so a query that matched sense 3 of どうも shows the "hello"
    // gloss instead of sense 1's "thank you". Falls back to senses.first.glosses.first
    // when the query is empty, the term is Japanese-script, or no gloss contains it
    // (the entry was returned via kanji/kana match, not gloss match).
    private func matchingGloss(for entry: DictionaryEntry, query: String) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty == false {
            for sense in entry.senses {
                for gloss in sense.glosses where gloss.lowercased().contains(needle) {
                    return gloss
                }
            }
        }
        return entry.senses.first?.glosses.first
    }

    // True if the query text appears in the entry's *primary* representation: the first
    // kanji headword, first kana reading, or any gloss of the first sense. Used to bubble
    // entries whose canonical meaning matches above entries that merely have the query
    // hidden in a later sense (e.g. ranks ハロー/今日は above どうも/毎度 for "hello").
    nonisolated private static func isPrimarySenseMatch(_ entry: DictionaryEntry, needle: String) -> Bool {
        if let kanji = entry.kanjiForms.first?.text, kanji.lowercased().contains(needle) { return true }
        if let kana = entry.kanaForms.first?.text, kana.lowercased().contains(needle) { return true }
        if let firstSense = entry.senses.first {
            for gloss in firstSense.glosses where gloss.lowercased().contains(needle) {
                return true
            }
        }
        return false
    }

    // Fan-out search: queries the dictionary in both Japanese and English modes,
    // dedupes by entryId (Japanese hits first so kanji/kana queries lead the list),
    // and writes the merged result set on the main actor. Debounced 250ms; older
    // tasks are cancelled when a new keystroke arrives.
    private func runDictionarySearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            searchResults = []
            parsedSegments = []
            searchError = nil
            isSearching = false
            return
        }
        guard let store = dictionaryStore else { return }

        isSearching = true
        let capturedSegmenter = segmenter
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }

            // Sentence-parse pass: if the query is Japanese and MeCab splits it into
            // ≥2 tokens, render one row per token via parsedSegmentsResultsSection
            // rather than chasing a literal whole-sentence dictionary match (which
            // never lands and just looks like "No Results"). Wildcards bypass this
            // path so users can intentionally search for literal patterns.
            let isWildcardQuery = trimmed.contains("*") || trimmed.contains("?")
            if isWildcardQuery == false,
               let parseSegmenter = capturedSegmenter,
               trimmed.unicodeScalars.contains(where: { (0x3040...0x309F).contains($0.value)
                                                       || (0x30A0...0x30FF).contains($0.value)
                                                       || (0x4E00...0x9FFF).contains($0.value) }) {
                let tokens = await Task.detached(priority: .userInitiated) {
                    WordsView.parseTokens(trimmed, using: parseSegmenter)
                }.value
                if tokens.count >= 2 {
                    let segments = await Task.detached(priority: .userInitiated) {
                        WordsView.resolveParsedSegments(tokens: tokens, store: store)
                    }.value
                    if Task.isCancelled { return }
                    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                    parsedSegments = segments
                    searchResults = []
                    searchError = nil
                    isSearching = false
                    // Multi-token sentence parses are nearly always "looking up this whole
                    // sentence" intents — record so history surfaces them without requiring
                    // the user to also press Return. HistoryStore dedupes by text.
                    historyStore.record(query: trimmed)
                    return
                }
            }

            // Result is .success(merged hits) or .failure(thrown error) so the UI can
            // distinguish "no hits" from "the query blew up." Either dictionary mode
            // throwing fails the whole task — no silent default to empty.
            let needle = trimmed.lowercased()
            // Romaji → kana conversion (e.g. "tabe" → "たべ") so wāpuro-style typing
            // surfaces Japanese hits without forcing the user to switch keyboards.
            // Returns nil if the input already contains kana/kanji or doesn't convert.
            let romajiKana = RomajiToKana.convert(trimmed)?.kana
            let outcome: Result<[DictionaryEntry], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let jp = try store.searchEntries(term: trimmed, mode: .japanese)
                    let en = try store.searchEntries(term: trimmed, mode: .english)
                    // Extra Japanese pass on the romaji-derived kana so substring matches
                    // (e.g. "tabe" → たべ → たべる, たべもの) flow through the same FTS path.
                    let jpRomaji: [DictionaryEntry]
                    if let kana = romajiKana, kana.isEmpty == false, kana != trimmed {
                        jpRomaji = try store.searchEntries(term: kana, mode: .japanese)
                    } else {
                        jpRomaji = []
                    }
                    var seen = Set<Int64>()
                    var combined: [DictionaryEntry] = []
                    combined.reserveCapacity(jp.count + jpRomaji.count + en.count)
                    for entry in jp where seen.insert(entry.entryId).inserted {
                        combined.append(entry)
                    }
                    for entry in jpRomaji where seen.insert(entry.entryId).inserted {
                        combined.append(entry)
                    }
                    for entry in en where seen.insert(entry.entryId).inserted {
                        combined.append(entry)
                    }
                    // Partition so entries whose primary representation (first headword,
                    // first reading, or first-sense glosses) contains the query come first.
                    // Romaji-derived kana is checked as a secondary needle so wāpuro queries
                    // like "tabe" lift 食べる above buried-sense matches just like "たべ" would.
                    let kanaNeedle = romajiKana?.lowercased()
                    var primary: [DictionaryEntry] = []
                    var secondary: [DictionaryEntry] = []
                    for entry in combined {
                        let isPrimary = Self.isPrimarySenseMatch(entry, needle: needle)
                            || (kanaNeedle.map { Self.isPrimarySenseMatch(entry, needle: $0) } ?? false)
                        if isPrimary {
                            primary.append(entry)
                        } else {
                            secondary.append(entry)
                        }
                    }
                    // Within primary, sort by entry_id ASC. JMdict IDs are roughly insertion
                    // order, and older entries are the canonical/common words — for greetings
                    // like ハロー (8516) vs 你好 (112034), this picks the right one even when
                    // JPDB frequency data is missing (as it is for most basic greetings).
                    primary.sort { $0.entryId < $1.entryId }
                    return .success(primary + secondary)
                } catch {
                    return .failure(error)
                }
            }.value

            if Task.isCancelled { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

            switch outcome {
            case .success(let merged):
                searchResults = merged
                searchError = nil
            case .failure(let error):
                searchResults = []
                searchError = String(describing: error)
            }
            // Clear any prior parsed-segments view since this code path is the
            // single-token / FTS-fallback branch.
            parsedSegments = []
            isSearching = false
        }
    }

    // MARK: - Helpers

    // True when any filter is active across notes or lists.
    var isFilterActive: Bool {
        !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty
    }

    // Returns saved words filtered by active note/list selection and sorted by the current saved sort order.
    var visibleWords: [SavedWord] {
        let filtered: [SavedWord]
        if isFilterActive {
            filtered = wordsStore.words.filter { word in
                let matchesNote = activeFilterNoteIDs.isEmpty || activeFilterNoteIDs.contains { word.sourceNoteIDs.contains($0) }
                let matchesList = activeFilterListIDs.isEmpty || activeFilterListIDs.contains { word.wordListIDs.contains($0) }
                return matchesNote && matchesList
            }
        } else {
            filtered = wordsStore.words
        }
        return sorted(filtered, by: savedSort)
    }

    // Returns history entries sorted by the current history sort order.
    var sortedHistory: [HistoryEntry] {
        switch historySort {
        case .newestFirst: return historyStore.entries.sorted { $0.lookedUpAt > $1.lookedUpAt }
        case .oldestFirst: return historyStore.entries.sorted { $0.lookedUpAt < $1.lookedUpAt }
        case .aToZ:        return historyStore.entries.sorted { $0.surface < $1.surface }
        case .zToA:        return historyStore.entries.sorted { $0.surface > $1.surface }
        }
    }

    // The word ids the user can select on the current tab — the universe for "Select All"
    // and the cap for "all selected". Saved tab → the visible favorites; History tab → the
    // `.entry` rows (query rows aren't words). Search/parse modes force edit mode off, so
    // they never reach the selection menu and default to empty here.
    var selectableWordIDs: [Int64] {
        if searchText.isEmpty && activeTab == .saved {
            return visibleWords.map(\.canonicalEntryID)
        }
        if searchText.isEmpty && activeTab == .history {
            return sortedHistory.filter { $0.kind == .entry }.map(\.canonicalEntryID)
        }
        return []
    }

    // Surface text for every selectable word id, so a batch list-add can materialize a
    // SavedWord for a History-only word that isn't saved yet. Saved words win over history
    // rows when both exist (their stored surface is canonical).
    var selectionSurfaces: [Int64: String] {
        var map: [Int64: String] = [:]
        for entry in historyStore.entries where entry.kind == .entry {
            map[entry.canonicalEntryID] = entry.surface
        }
        for word in wordsStore.words {
            map[word.canonicalEntryID] = word.surface
        }
        return map
    }

    // Sorts a saved-word array by the given order.
    func sorted(_ words: [SavedWord], by order: WordsSortOrder) -> [SavedWord] {
        switch order {
        case .newestFirst: return words.sorted { $0.savedAt > $1.savedAt }
        case .oldestFirst: return words.sorted { $0.savedAt < $1.savedAt }
        case .aToZ:        return words.sorted { $0.surface < $1.surface }
        case .zToA:        return words.sorted { $0.surface > $1.surface }
        }
    }

    // Returns true when the given entry is already in the saved words list.
    func isSaved(_ entry: DictionaryEntry) -> Bool {
        wordsStore.words.contains { $0.canonicalEntryID == entry.entryId }
    }

    // Returns true when the given canonical entry id is in the saved words list.
    func isSavedByID(_ id: Int64) -> Bool {
        wordsStore.words.contains { $0.canonicalEntryID == id }
    }

    // Saves or unfavorites an entry from the Words tab star.
    //
    // Unsave is a HARD remove rather than a `wordsStore.toggle(...)` call: that toggle
    // only clears the encountered surface but leaves any note attribution in place,
    // which means tapping the star on a song-saved word would no-op (encounteredSet
    // would empty but noteIDs would still contain the song, so the SavedWord survives).
    // The Words tab star has no song context, so the user's intent is unambiguous —
    // "make this not a favorite anymore" — and full removal is the only state change
    // that delivers that.
    func toggleSave(_ entry: DictionaryEntry) {
        toggleSaveWord(entryID: entry.entryId, surface: entry.primarySearchSurface, materialized: entry)
    }

    // The one save/unsave used by every word row. Unsave is a full remove (favorite ==
    // saved == present in WordsStore). On save we seed smart-default senses from the
    // materialized entry when we have it, else resolve once from the dictionary store — so
    // a row whose DictionaryEntry hasn't been fetched yet (pending history/saved row) still
    // saves with sensible senses. Replaces the old toggleSave/toggleSaveHistory split.
    func toggleSaveWord(entryID: Int64, surface: String, materialized: DictionaryEntry?) {
        if isSavedByID(entryID) {
            wordsStore.remove(id: entryID)
            return
        }
        let senseIDs: [Int64]
        if let materialized {
            senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: materialized)
        } else if let store = dictionaryStore,
                  let resolved = try? store.lookupEntry(entryID: entryID) {
            senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: resolved)
        } else {
            senseIDs = []
        }
        wordsStore.toggle(
            canonicalEntryID: entryID,
            storedSurface: materialized?.primarySearchSurface ?? surface,
            defaultSenseIDs: senseIDs
        )
    }

    // Single active list/note filter, when exactly one is on — the unambiguous "container
    // you're viewing", used to offer the contextual "Remove from <container>" row action.
    var singleActiveListID: UUID? { activeFilterListIDs.count == 1 ? activeFilterListIDs.first : nil }
    var singleActiveNoteID: UUID? { activeFilterNoteIDs.count == 1 ? activeFilterNoteIDs.first : nil }

    // Display name of a list for the contextual remove label.
    func listName(_ id: UUID) -> String { wordListsStore.lists.first { $0.id == id }?.name ?? "List" }

    // Display title of a note for the contextual remove label (falls back to "Untitled Note").
    func noteName(_ id: UUID) -> String {
        let trimmed = notesStore.note(withID: id)?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }

    // Returns the saved word for a history entry if it exists, otherwise a minimal SavedWord for display.
    func wordForHistory(_ entry: HistoryEntry) -> SavedWord {
        wordsStore.words.first { $0.canonicalEntryID == entry.canonicalEntryID }
            ?? SavedWord(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
    }

    // Number of distinct lemma candidates a surface resolves to. Cheap enough to call in a
    // context-menu builder (built lazily on long-press, one row at a time) so "Choose Lemma…"
    // only appears when there's actually an alternative to pick.
    func lemmaCandidateCount(for surface: String) -> Int {
        (segmenter?.lemmaCandidates(for: surface) ?? []).count
    }

    // Opens the disambiguation picker for a saved card; choosing re-points the card to the
    // selected lemma's entry (fixes a した→下 mis-save by re-pointing it to する).
    // One lemma re-point for any word row. Re-points the word wherever it actually lives —
    // the saved card and/or the history entry — so a single row action keeps both stores
    // consistent no matter which tab you triggered it from.
    func chooseLemma(entryID: Int64, surface: String) {
        let candidates = segmenter?.lemmaCandidates(for: surface) ?? []
        guard candidates.count > 1 else { return }
        lemmaPickerContext = WordsLemmaPickerContext(
            surface: surface,
            candidates: candidates,
            onChoose: { lemma, newID in
                if wordsStore.words.contains(where: { $0.canonicalEntryID == entryID }) {
                    wordsStore.repoint(fromEntryID: entryID, toEntryID: newID, lemma: lemma)
                }
                if historyStore.entries.contains(where: { $0.kind == .entry && $0.canonicalEntryID == entryID }) {
                    historyStore.repoint(historyID: "e:\(entryID)", toEntryID: newID, surface: lemma)
                }
            }
        )
    }

    // Toggles save/unsave for an entry surfaced in the browse-frequency sheet.
    func handleBrowseToggleSave(_ entry: DictionaryEntry) {
        wordsStore.toggle(
            canonicalEntryID: entry.entryId,
            storedSurface: entry.primarySearchSurface,
            defaultSenseIDs: DefaultSenseSelection.defaultSelectedSenseIDs(for: entry)
        )
    }

    // Routes a picked kanji from the radical input sheet into the search field on the Words tab.
    func handleRadicalSelectKanji(_ kanji: String) {
        isRadicalInputPresented = false
        searchText = kanji
    }

    // Routes a recognized character from the handwriting sheet into the search field.
    func handleHandwritingSelect(_ character: String) {
        isHandwritingPresented = false
        searchText = character
    }

    // Opens one browse-frequency result in the detail sheet, dismissing the browse sheet first.
    func handleBrowseSelectEntry(_ entry: DictionaryEntry) {
        isBrowseFrequencyPresented = false
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        // Defer to next runloop so the sheet dismissal animation doesn't race the detail presentation.
        DispatchQueue.main.async {
            selectedDetailWord = detailWord(entryID: entry.entryId, surfaceHint: entry.primarySearchSurface)
        }
    }
}

// Carries everything the "Choose Lemma…" sheet needs for one row. The `onChoose` closure
// captures the row identity and store call (re-point saved card vs history row), keeping the
// shared LemmaPickerSheet presentation generic across both row types.
struct WordsLemmaPickerContext: Identifiable {
    let id = UUID()
    let surface: String
    let candidates: [String]
    let onChoose: (_ lemma: String, _ canonicalEntryID: Int64) -> Void
}

#Preview {
    ContentView(selectedTab: .words)
}
