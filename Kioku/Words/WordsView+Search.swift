import SwiftUI

// Dictionary-search filter menu and ranking/filter helpers. The debounced search task
// itself lives in WordsView.runDictionarySearch; this file covers the controls that
// narrow or reorder its results (sort mode, common-only, part-of-speech) and the
// shared open/toggle-save actions for search hits.
extension WordsView {
    // MARK: - Search filter menu

    // Live dictionary-search filter/sort control. Shown in the search bar's trailing slot while a
    // query is active (replacing the note/list funnel, which only applies to the saved/history
    // lists). Drives `filteredSearchResults` via the same @State the helpers below read/write.
    // The label uses the filled funnel when any control is narrowing/reordering so the active
    // state is glanceable, matching the note/list funnel's affordance.
    var dictionarySearchFilterMenu: some View {
        Menu {
            Picker("Sort", selection: $searchSortMode) {
                ForEach(DictionarySearchSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Divider()

            Toggle(isOn: $searchCommonWordsOnly) {
                Label("Common Words Only", systemImage: "star")
            }

            Toggle(isOn: $searchShowKanji) {
                Label("Show Kanji", systemImage: "character.textbox")
            }

            Picker("Frequency", selection: $searchFrequencyTier) {
                ForEach(DictionaryFrequencyTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }

            let partsOfSpeech = availableSearchPartsOfSpeech
            if partsOfSpeech.isEmpty == false {
                Menu {
                    ForEach(partsOfSpeech, id: \.self) { label in
                        Button {
                            toggleSearchPartOfSpeech(label)
                        } label: {
                            if searchSelectedPartsOfSpeech.contains(label) {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    Label("Part of Speech: \(searchPartOfSpeechSummary)", systemImage: "textformat.abc")
                }
            }

            if hasActiveSearchControls {
                Divider()
                Button(role: .destructive) {
                    resetSearchControls()
                } label: {
                    Label("Reset Filters", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: hasActiveSearchControls
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .font(.system(size: 22))
                .foregroundStyle(hasActiveSearchControls ? Color.accentColor : Color.secondary)
        }
        .accessibilityLabel("Filter Search Results")
    }

    // MARK: - Search helpers

    // True if the query text appears in the entry's *primary* representation: the first
    // kanji headword, first kana reading, or any gloss of the first sense. Used to bubble
    // entries whose canonical meaning matches above entries that merely have the query
    // hidden in a later sense (e.g. ranks ハロー/今日は above どうも/毎度 for "hello").
    nonisolated static func isPrimarySenseMatch(_ entry: DictionaryEntry, needle: String) -> Bool {
        if let kanji = entry.kanjiForms.first?.text, kanji.lowercased().contains(needle) { return true }
        if let kana = entry.kanaForms.first?.text, kana.lowercased().contains(needle) { return true }
        if let firstSense = entry.senses.first {
            for gloss in firstSense.glosses where gloss.lowercased().contains(needle) {
                return true
            }
        }
        return false
    }

    // True when any headword or kana form equals one of the needles exactly (case-insensitive).
    // Keeps exact matches above substring hits in search results regardless of entry id
    // (まさか must beat たまさか for query "masaka").
    nonisolated static func isExactSurfaceMatch(_ entry: DictionaryEntry, needles: [String]) -> Bool {
        entry.kanjiForms.contains { needles.contains($0.text.lowercased()) }
            || entry.kanaForms.contains { needles.contains($0.text.lowercased()) }
    }

    // Returns available POS labels from the current raw search result set.
    var availableSearchPartsOfSpeech: [String] {
        var seen = Set<String>()
        var labels: [String] = []

        for entry in searchResults {
            for label in entry.searchPartOfSpeechLabels where seen.insert(label).inserted {
                labels.append(label)
            }
        }

        return labels
    }

    // Returns the current result set after applying common-word, POS, and sort controls.
    var filteredSearchResults: [DictionaryEntry] {
        let filtered = searchResults.filter { entry in
            if searchCommonWordsOnly && entry.isCommonSearchEntry == false {
                return false
            }

            if let maxRank = searchFrequencyTier.maxRank {
                guard let rank = entry.jpdbRank, rank <= maxRank else { return false }
            }

            if searchSelectedPartsOfSpeech.isEmpty == false {
                let entryParts = Set(entry.searchPartOfSpeechLabels)
                if entryParts.isDisjoint(with: searchSelectedPartsOfSpeech) {
                    return false
                }
            }

            return true
        }

        switch searchSortMode {
        case .relevance:
            return filtered
        case .commonFirst:
            return filtered.enumerated().sorted { lhs, rhs in
                if lhs.element.isCommonSearchEntry != rhs.element.isCommonSearchEntry {
                    return lhs.element.isCommonSearchEntry && rhs.element.isCommonSearchEntry == false
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        case .alphabetical:
            return filtered.sorted {
                $0.primarySearchSurface.localizedCaseInsensitiveCompare($1.primarySearchSurface) == .orderedAscending
            }
        }
    }

    // Describes the active POS selection in the search filter summary line.
    var searchPartOfSpeechSummary: String {
        if searchSelectedPartsOfSpeech.isEmpty {
            return availableSearchPartsOfSpeech.isEmpty ? "Unavailable" : "Any"
        }

        return searchSelectedPartsOfSpeech.sorted().joined(separator: ", ")
    }

    // True when any live dictionary-search control is narrowing or reordering the result set.
    // searchShowKanji defaults on, so hiding kanji (false) counts as an active filter.
    var hasActiveSearchControls: Bool {
        searchCommonWordsOnly || searchFrequencyTier != .any || searchSortMode != .relevance || searchSelectedPartsOfSpeech.isEmpty == false || searchShowKanji == false
    }

    // Whether the inline Tatoeba example-sentence section belongs below the entry list for the
    // current query/results. Thin wrapper over the pure decision so the view can read it directly.
    var shouldShowSentenceResults: Bool {
        Self.shouldSurfaceSentences(
            query: searchText,
            entryCount: filteredSearchResults.count,
            sentenceCount: sentenceResults.count,
            hasParsedSegments: parsedSegments.isEmpty == false
        )
    }

    // Pure decision (unit-tested in WordsSentenceSurfacingTests): example sentences are worth
    // showing inline only when they add something the word detail's own examples section doesn't.
    // That's a phrase query — multi-token Japanese (`hasParsedSegments`) or a space-separated /
    // English phrase — or a query whose entry matches are sparse. A plain single-word lookup with
    // plenty of entries is left clean; its examples live one tap away in the word detail.
    nonisolated static func shouldSurfaceSentences(
        query: String,
        entryCount: Int,
        sentenceCount: Int,
        hasParsedSegments: Bool
    ) -> Bool {
        guard sentenceCount > 0 else { return false }
        if hasParsedSegments { return true }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") { return true }
        return entryCount <= 2
    }

    // Removes POS selections that are no longer available after a new search result set arrives.
    func pruneUnavailableSearchPartsOfSpeech() {
        searchSelectedPartsOfSpeech.formIntersection(Set(availableSearchPartsOfSpeech))
    }

    // Toggles one POS label in the search filter menu.
    func toggleSearchPartOfSpeech(_ label: String) {
        if searchSelectedPartsOfSpeech.contains(label) {
            searchSelectedPartsOfSpeech.remove(label)
        } else {
            searchSelectedPartsOfSpeech.insert(label)
        }
    }

    // Resets live dictionary-search controls back to the default broad result set.
    func resetSearchControls() {
        searchCommonWordsOnly = false
        searchFrequencyTier = .any
        searchSortMode = .relevance
        searchSelectedPartsOfSpeech = []
        searchShowKanji = true
    }

    // Opens one live search result in the detail sheet and records it in lookup history.
    func openSearchResult(_ entry: DictionaryEntry) {
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        selectedDetailWord = detailWord(entryID: entry.entryId, surfaceHint: entry.primarySearchSurface)
    }

    // Renders the kanji-matches section that sits at the TOP of the search results
    // list. Returns EmptyView when no kanji matched the query, so the list doesn't
    // get a phantom section. The rows are untitled (no "Kanji" header) — their tinted
    // background and distinct shape already set them apart; tapping one opens
    // KanjiDetailView, not WordDetailView.
    @ViewBuilder
    var kanjiResultsSection: some View {
        if searchShowKanji, kanjiSearchResults.isEmpty == false {
            Section {
                ForEach(kanjiSearchResults) { info in
                    HStack(spacing: 12) {
                        Button {
                            isSearchFieldFocused = false
                            presentedKanjiInfo = info
                        } label: {
                            kanjiResultRowContent(info)
                        }
                        .buttonStyle(.plain)
                        kanjiSaveStar(literal: info.literal)
                    }
                    .listRowBackground(Color.accentColor.opacity(0.06))
                }
            }
        }
    }

    // The visual content of one kanji search-result row. Deliberately UNLIKE the
    // word-row shape: a large kanji glyph in a tinted square tile leads (instant
    // "this is a kanji, not a word"), followed by the kanji's English meanings and
    // a horizontal pill row of grade / JLPT / stroke-count metadata. The trailing save
    // star is a sibling of this content (added by the call site) so it can sit outside
    // the row's open-detail tap target — mirroring the word row's speaker/star layout.
    @ViewBuilder
    func kanjiResultRowContent(_ info: KanjiInfo) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(info.literal)
                .font(.system(size: 38, weight: .medium))
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
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
                        kanjiResultMetaPill(grade == 8 ? "Secondary" : "Grade \(grade)")
                    }
                    if let jlpt = info.jlptLevel {
                        kanjiResultMetaPill("JLPT N\(jlpt)")
                    }
                    if let strokes = info.strokeCount {
                        kanjiResultMetaPill("\(strokes) strokes")
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // Small pill chip for kanji-row metadata. Local to this file so the visual
    // weight stays consistent across kanji rows; the WordDetailView's metadataLabel
    // is a near-twin but lives on a different host type, so we duplicate the look
    // rather than thread a shared style through both call sites.
    @ViewBuilder
    func kanjiResultMetaPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.secondary.opacity(0.15))
            )
    }

    // Picks the gloss to display for a result row. Walks senses in their canonical
    // order_index order and returns the first gloss whose text (case-folded) contains
    // the search term — so a query that matched sense 3 of どうも shows the "hello"
    // gloss instead of sense 1's "thank you". Falls back to senses.first.glosses.first
    // when the query is empty, the term is Japanese-script, or no gloss contains it
    // (the entry was returned via kanji/kana match, not gloss match).
    // Not private: called from WordsView.body / resultsList in the main file.
    func matchingGloss(for entry: DictionaryEntry, query: String) -> String? {
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

    // Fan-out search: queries the dictionary in both Japanese and English modes,
    // dedupes by entryId (Japanese hits first so kanji/kana queries lead the list),
    // and writes the merged result set on the main actor. Debounced 250ms; older
    // tasks are cancelled when a new keystroke arrives.
    // Not private: called from WordsView.body's onChange/onSubmit handlers in the main file.
    func runDictionarySearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            searchResults = []
            kanjiSearchResults = []
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
                    let parseKanji = await Task.detached(priority: .userInitiated) {
                        (try? store.searchKanji(query: trimmed, kanaQuery: nil, limit: 6)) ?? []
                    }.value
                    if Task.isCancelled { return }
                    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                    parsedSegments = segments
                    searchResults = []
                    kanjiSearchResults = parseKanji
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
                    // for query "masaka" — both are primary because たまさか contains まさか). Then
                    // by FREQUENCY, most-common first — an English query like "science" must put
                    // 科学 (jpdb 5318) above the loanword サイエンス (unranked) and the abbreviation
                    // ＳＦ (17413). entry_id is only the FINAL fallback, for the no-frequency-data
                    // case the older comment described (ハロー vs 你好); it is a weak frequency
                    // proxy (older ≠ commoner: サイエンス is older than 科学 yet far rarer), so it
                    // must not override the real signal. Uses the same jpdb+zipf blend as the
                    // frequency badge, with jpdb rank as the sharper tiebreak when the blend ties
                    // (科学 and サイエンス share a wordfreq Zipf but jpdb separates them).
                    let exactNeedles = [needle, kanaNeedle].compactMap { $0 }
                    primary.sort { lhs, rhs in
                        let lhsExact = Self.isExactSurfaceMatch(lhs, needles: exactNeedles)
                        let rhsExact = Self.isExactSurfaceMatch(rhs, needles: exactNeedles)
                        if lhsExact != rhsExact { return lhsExact }
                        let lhsScore = FrequencyData(jpdbRank: lhs.jpdbRank, wordfreqZipf: lhs.wordfreqZipf).normalizedScore ?? -1
                        let rhsScore = FrequencyData(jpdbRank: rhs.jpdbRank, wordfreqZipf: rhs.wordfreqZipf).normalizedScore ?? -1
                        if lhsScore != rhsScore { return lhsScore > rhsScore }
                        let lhsRank = lhs.jpdbRank ?? Int.max
                        let rhsRank = rhs.jpdbRank ?? Int.max
                        if lhsRank != rhsRank { return lhsRank < rhsRank }
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

            // Kanji that match the query — direct literals, English meanings, or kana
            // readings. Surfaced at the top of the results list so a "rain" or 火 query
            // leads with the kanji itself rather than burying it in compound words.
            let kanjiHits = await Task.detached(priority: .userInitiated) {
                (try? store.searchKanji(query: trimmed, kanaQuery: romajiKana, limit: 6)) ?? []
            }.value

            if Task.isCancelled { return }
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

            switch outcome {
            case .success(let merged):
                searchResults = merged
                kanjiSearchResults = kanjiHits
                sentenceResults = sentences
                searchError = nil
                // Drop any POS selections that no longer appear in the fresh result set so a
                // stale filter from a prior query can't silently hide every new hit.
                pruneUnavailableSearchPartsOfSpeech()
            case .failure(let error):
                searchResults = []
                kanjiSearchResults = []
                sentenceResults = []
                searchError = String(describing: error)
            }
            // Clear any prior parsed-segments view since this code path is the
            // single-token / FTS-fallback branch.
            parsedSegments = []
            isSearching = false
        }
    }
}
