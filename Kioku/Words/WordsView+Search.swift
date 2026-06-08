import SwiftUI

// Dictionary-search content, filters, and the debounced search task that powers them.
// Covers the search results list section and the helpers that compute available POS labels,
// sort/filter results, and toggle save state for hits. The filter UI itself (toolbar menu)
// has been removed — these helpers are kept so a replacement UI can rewire to them later.
extension WordsView {
    // MARK: - Search results view

    @ViewBuilder
    var searchResultsContent: some View {
        if parsedSegments.isEmpty == false {
            parsedSegmentsResultsSection
        } else if filteredSearchResults.isEmpty {
            Section {
                Text(searchText.isEmpty ? "" : "No results")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(filteredSearchResults, id: \.entryId) { entry in
                    DictionarySearchResultRow(
                        entry: entry,
                        isSaved: isSaved(entry),
                        onToggleSave: { toggleSave(entry) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openSearchResult(entry)
                    }
                }
            } header: {
                Text("\(filteredSearchResults.count) Result\(filteredSearchResults.count == 1 ? "" : "s")")
            }
        }
    }

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
    var hasActiveSearchControls: Bool {
        searchCommonWordsOnly || searchSortMode != .relevance || searchSelectedPartsOfSpeech.isEmpty == false
    }

    // Starts or replaces the debounced dictionary-search task for the current query and mode.
    func startSearchTask(for query: String) {
        searchTask?.cancel()
        searchTask = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            searchResults = []
            parsedSegments = []
            return
        }

        let alternateKana = convertedKana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWildcardQuery = trimmedQuery.contains("*") || trimmedQuery.contains("?")
        // Only consider sentence-parse mode for Japanese input — English headword lookups
        // ("light", "to shine") should always stay in entry-list mode.
        let sentenceCandidateSegmenter: (any TextSegmenting)? = (isWildcardQuery == false && searchMode == .japanese) ? segmenter : nil

        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }

            guard let store = dictionaryStore, Task.isCancelled == false else { return }
            let mode = searchMode

            // Run segmentation first. If the query produces ≥2 non-boundary tokens, switch
            // to Pleco-style row-per-segment mode and skip the literal entry search entirely.
            if let parseSegmenter = sentenceCandidateSegmenter {
                let tokens = await Task.detached(priority: .userInitiated) {
                    WordsView.parseTokens(trimmedQuery, using: parseSegmenter)
                }.value
                if tokens.count >= 2 {
                    let segments = await Task.detached(priority: .userInitiated) {
                        WordsView.resolveParsedSegments(tokens: tokens, store: store)
                    }.value
                    guard Task.isCancelled == false,
                          searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery,
                          searchMode == mode else {
                        return
                    }
                    parsedSegments = segments
                    searchResults = []
                    return
                }
            }

            let results = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if isWildcardQuery {
                        var entries = (try? store.searchEntriesByPattern(trimmedQuery)) ?? []
                        if let alt = alternateKana, alt.isEmpty == false, alt != trimmedQuery {
                            let altEntries = (try? store.searchEntriesByPattern(alt)) ?? []
                            let existing = Set(entries.map(\.entryId))
                            entries += altEntries.filter { existing.contains($0.entryId) == false }
                        }
                        continuation.resume(returning: entries)
                        return
                    }
                    var entries = (try? store.searchEntries(term: trimmedQuery, mode: mode)) ?? []
                    if let alt = alternateKana, alt.isEmpty == false, alt != trimmedQuery {
                        let altEntries = (try? store.searchEntries(term: alt, mode: .japanese)) ?? []
                        let existing = Set(entries.map(\.entryId))
                        entries += altEntries.filter { existing.contains($0.entryId) == false }
                    }
                    continuation.resume(returning: entries)
                }
            }

            guard Task.isCancelled == false,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery,
                  searchMode == mode else {
                return
            }

            searchResults = results
            parsedSegments = []
            pruneUnavailableSearchPartsOfSpeech()
        }
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
        searchSortMode = .relevance
        searchSelectedPartsOfSpeech = []
    }

    // Opens one live search result in the detail sheet and records it in lookup history.
    func openSearchResult(_ entry: DictionaryEntry) {
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        selectedDetailWord = detailWord(entryID: entry.entryId, surfaceHint: entry.primarySearchSurface)
    }
}
