import SwiftUI
import AVFoundation

// Tabs available in the Words screen.
enum WordsTab { case saved, history }

// Sort options for both saved words and history.
enum WordsSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case aToZ
    case zToA
    case mostWrong
    case worstAccuracy
    case mostReviewed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        case .aToZ: "A to Z"
        case .zToA: "Z to A"
        case .mostWrong: "Most Wrong"
        case .worstAccuracy: "Worst Accuracy"
        case .mostReviewed: "Most Reviewed"
        }
    }
}

// Stat-based scope applied on top of the note/list filter in the saved-words view.
enum WordsStatScope: String {
    case none
    case markedWrong
    case dueForReview
    case neverReviewed
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
    // Read-tab reading maps, forwarded to WordDetailView so example sentences get furigana.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()
    // Receives cross-tab routing requests from ContentView.
    var pendingRoute: Binding<WordsRoute?> = .constant(nil)

    @EnvironmentObject var wordsStore: WordsStore
    @EnvironmentObject var wordListsStore: WordListsStore
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject var reviewStore: ReviewStore

    @State var selectedDetailWord: SavedWord?
    // Reading that was active in the lookup sheet when this word detail was opened, if available.
    @State var selectedDetailReading: String?
    @State var selectedDetailSublatticePaths: [[String]] = []
    @State var activeFilterNoteIDs: Set<UUID> = []
    @State var activeFilterListIDs: Set<UUID> = []
    @State var statScope: WordsStatScope = .none
    // Active JLPT-level scope (the N-number, 5…1), or nil for no level filter. Single-value like
    // the other "Show" scopes — selecting a level clears note/list/stat. Levels come from the
    // dictionary's entry_jlpt_level map via dictionaryStore.jlptLevel(for:).
    @State var jlptLevel: Int? = nil
    @State var isFilterSheetPresented = false
    // Drives the "Choose Lemma…" disambiguation sheet for saved-word and history rows.
    @State var lemmaPickerContext: WordsLemmaPickerContext?
    @State var editMode: EditMode = .inactive
    // ja-JP text-to-speech for the per-row pronunciation buttons (mirrors WordDetailView.speak).
    @State var rowSpeechSynthesizer = AVSpeechSynthesizer()
    @State var selectedWordIDs: Set<Int64> = []
    @State var isBatchRemoveConfirmPresented = false
    @State var isBatchRemoveHistoryConfirmPresented = false
    @State var isBatchListSheetPresented = false
    @State var isCSVImportPresented = false
    @State var isSubtitleImportPresented = false
    @State var isSubtitleSearchPresented = false
    @State var isBrowseFrequencyPresented = false
    @State var isBrowseProficiencyPresented = false
    @State var isSentenceSearchPresented = false
    @State var isRadicalInputPresented = false
    @State var isHandwritingPresented = false
    @State var activeTab: WordsTab = .history
    // A "Show" scope alongside Favorites/note/list: when true the list shows only the typed
    // free-text searches (.query history), which are otherwise kept out of the lookup History
    // so they don't disrupt its flow. Mutually exclusive with the other scopes.
    @State var showRecentSearches = false
    @AppStorage("savedWordsSortOrder") var savedSortOrder: String = WordsSortOrder.newestFirst.rawValue
    @AppStorage("historySortOrder") var historySortOrderRaw: String = WordsSortOrder.newestFirst.rawValue
    @State var searchText = ""
    // convertedKana removed — only the deleted startSearchTask duplicate read it;
    // the live search path derives romaji→kana inline in runDictionarySearch.
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
    // Tatoeba example sentences matching the current query, surfaced inline below entry
    // results. Folds the old standalone "Search Example Sentences" tool into the one search
    // box — shown only when sentences add value (phrase query or sparse entry matches), so
    // a plain single-word lookup (whose examples already live in the word detail) stays clean.
    @State var sentenceResults: [SentencePair] = []
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
        let inStore = wordsStore.words.contains(where: { $0.canonicalEntryID == entryID })
        WOTDDiag.log("detailWord entryID=\(entryID) hint=\(surfaceHint?.isEmpty == false) inStore=\(inStore) dictReady=\(dictionaryStore != nil)")
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
            let word = detailWord(entryID: entryID, surfaceHint: surface)
            WOTDDiag.log("consume .detail entryID=\(entryID) resolved=\(word != nil)")
            if let word {
                activeTab = .saved
                showRecentSearches = false
                selectedDetailWord = word
                selectedDetailReading = reading
                selectedDetailSublatticePaths = sublatticePaths
                // Opening a word via a deep link (e.g. the Word of the Day notification) is a
                // lookup like any other, so record it to history — the search-result and browse
                // paths already do this alongside their own `selectedDetailWord =` assignments.
                historyStore.record(canonicalEntryID: word.canonicalEntryID, surface: word.surface)
            }

        case let .search(query):
            activeTab = .saved
            showRecentSearches = false
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
                let _ = WOTDDiag.log("sheet PRESENTING entryID=\(word.canonicalEntryID)")
                WordDetailView(
                    word: word,
                    reading: selectedDetailReading,
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    initialSublatticePaths: selectedDetailSublatticePaths,
                    surfaceReadingData: surfaceReadingData,
                    kanjiReadingFallback: kanjiReadingFallback
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
            .sheet(isPresented: $isSubtitleImportPresented) {
                SubtitleImportView(
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    surfaceReadingData: surfaceReadingData,
                    kanjiReadingFallback: kanjiReadingFallback
                )
                    .environmentObject(wordsStore)
                    .environmentObject(wordListsStore)
                    .environmentObject(notesStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isSubtitleSearchPresented) {
                SubtitleSearchView(
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    surfaceReadingData: surfaceReadingData,
                    kanjiReadingFallback: kanjiReadingFallback
                )
                    .environmentObject(wordsStore)
                    .environmentObject(wordListsStore)
                    .environmentObject(notesStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isHandwritingPresented) {
                // Opens at ~2/3 height so the search field / results above stay visible while
                // drawing; still draggable to full height for more canvas room.
                HandwritingInputView(
                    onSelectCharacter: handleHandwritingSelect,
                    onDeleteBackward: handleHandwritingDeleteBackward
                )
                    .presentationDetents([.fraction(0.66), .large])
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
            .sheet(isPresented: $isBrowseProficiencyPresented) {
                BrowseProficiencyView(
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
                    statScope: $statScope,
                    jlptLevel: $jlptLevel,
                    showSavedWords: Binding(
                        get: { activeTab == .saved },
                        set: { activeTab = $0 ? .saved : .history }
                    ),
                    showRecentSearches: $showRecentSearches,
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
                .environmentObject(reviewStore)
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
            // Consume cross-tab routes from ContentView (e.g. the lookup sheet's magnifying-glass
            // "open in Words" action). onAppear catches a route set before this tab appeared;
            // onChange catches one set while it's already on screen. This wiring was dropped in
            // the Words-tab rebuild, which left consumePendingRoute orphaned — so the magnifying
            // glass switched tabs but never opened the detail view.
            .onAppear {
                consumePendingRoute(pendingRoute.wrappedValue)
            }
            .onChange(of: pendingRoute.wrappedValue) { _, route in
                consumePendingRoute(route)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // customSearchBar moved to WordsView+SearchBar.swift (the overflow menu, search
    // field, and trailing filter control) to keep this file under the line-count invariant.

    private var resultsList: some View {
        // ONE selection model for every word row, whichever tab it lives on: a word is
        // identified by its canonical entry id (Int64), so Saved, History, and search-result
        // rows all select into the same selectedWordIDs set. That's what lets the batch menu
        // be a single shared interface instead of per-tab silos. History `.query` rows (free-
        // text searches with no word behind them) carry no Int64 tag, so they're simply not
        // selectable — which is correct, you can't add a search phrase to a list.
        List(selection: $selectedWordIDs) {
            if searchText.isEmpty && showRecentSearches {
                // Recent Searches scope: only the typed free-text queries, separated out of
                // History so they don't interrupt the word-lookup flow.
                recentSearchesContent
            } else if searchText.isEmpty && activeTab == .saved {
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
                // filteredSearchResults applies the live sort + common-only + POS controls
                // (WordsView+Search.swift) on top of the raw `searchResults` the fan-out search
                // populates. With no controls active it returns the set unchanged, so the default
                // experience is identical to rendering `searchResults` directly.
                ForEach(filteredSearchResults, id: \.entryId) { entry in
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

            // Inline example sentences from the Tatoeba corpus. Replaces the old standalone
            // "Search Example Sentences" tool: it appears in the same results list, beneath the
            // entries, but only for phrase/sparse queries (see shouldShowSentenceResults).
            if shouldShowSentenceResults {
                Section("Example Sentences") {
                    ForEach(Array(sentenceResults.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pair.japanese)
                                .font(.body)
                            Text(pair.english)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .textSelection(.enabled)
                    }
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

    // (isPrimarySenseMatch / isExactSurfaceMatch moved to WordsView+Search.swift — they're
    // search-ranking helpers, and this file sits at the 1000-line invariant cap.)

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
            sentenceResults = []
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
               ScriptClassifier.containsJapanese(trimmed) {
                let tokens = await Task.detached(priority: .userInitiated) {
                    WordsView.parseTokens(trimmed, using: parseSegmenter)
                }.value
                if tokens.count >= 2 {
                    let segments = await Task.detached(priority: .userInitiated) {
                        WordsView.resolveParsedSegments(tokens: tokens, store: store)
                    }.value
                    // A multi-token query is a phrase — pull matching corpus sentences so the
                    // whole-phrase lookup the user almost certainly wants is one section away.
                    let sentences = await Task.detached(priority: .userInitiated) {
                        (try? store.searchSentences(query: trimmed, limit: 25)) ?? []
                    }.value
                    if Task.isCancelled { return }
                    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                    parsedSegments = segments
                    searchResults = []
                    sentenceResults = sentences
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
                    // Within primary: EXACT surface/kana matches first (まさか must beat たまさか
                    // for query "masaka" — both are primary because たまさか contains まさか, and
                    // the entry-id tiebreak alone happened to rank たまさか higher). Then entry_id
                    // ASC: JMdict IDs are roughly insertion order, and older entries are the
                    // canonical/common words — for greetings like ハロー (8516) vs 你好 (112034),
                    // this picks the right one even when JPDB frequency data is missing.
                    let exactNeedles = [needle, kanaNeedle].compactMap { $0 }
                    // primary.sort { $0.entryId < $1.entryId }
                    primary.sort { lhs, rhs in
                        let lhsExact = Self.isExactSurfaceMatch(lhs, needles: exactNeedles)
                        let rhsExact = Self.isExactSurfaceMatch(rhs, needles: exactNeedles)
                        if lhsExact != rhsExact { return lhsExact }
                        return lhs.entryId < rhs.entryId
                    }
                    return .success(primary + secondary)
                } catch {
                    return .failure(error)
                }
            }.value

            // Corpus example sentences for the same query, loaded alongside the entries.
            // Cheap FTS; `shouldShowSentenceResults` decides whether they actually render,
            // so a single-word lookup that returns plenty of entries won't surface them.
            let sentences = await Task.detached(priority: .userInitiated) {
                (try? store.searchSentences(query: trimmed, limit: 25)) ?? []
            }.value

            if Task.isCancelled { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

            switch outcome {
            case .success(let merged):
                searchResults = merged
                sentenceResults = sentences
                searchError = nil
                // Drop any POS selections that no longer appear in the fresh result set so a
                // stale filter from a prior query can't silently hide every new hit.
                pruneUnavailableSearchPartsOfSpeech()
            case .failure(let error):
                searchResults = []
                sentenceResults = []
                searchError = String(describing: error)
            }
            // Clear any prior parsed-segments view since this code path is the
            // single-token / FTS-fallback branch.
            parsedSegments = []
            isSearching = false
        }
    }

    // MARK: - Helpers
    //
    // The data-derivation helpers and row actions (visibleWords, sortedHistory, the
    // shared selection model, save/unsave, lemma re-pointing, and the kanji-discovery
    // sheet callbacks) live in WordsView+Actions.swift to keep this file under the
    // line-count invariant.
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
