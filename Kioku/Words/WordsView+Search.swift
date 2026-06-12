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
