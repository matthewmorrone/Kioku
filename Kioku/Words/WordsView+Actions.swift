import SwiftUI

// Data-derivation helpers and row actions for the Words screen: filtered/sorted word
// and history collections, the shared selection model, save/unsave, lemma re-pointing,
// and the kanji-discovery sheet callbacks. Extracted from WordsView so the primary
// file stays under the line-count invariant.
extension WordsView {
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
        // Recent Searches shows only free-text query rows, which carry no word identity —
        // nothing here is selectable, so don't let "Select All" reach hidden history entries.
        if showRecentSearches { return [] }
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
        // Append (don't replace) and keep the sheet up: characters compose directly in the
        // search field, visible above the 2/3-height handwriting sheet.
        // isHandwritingPresented = false
        // searchText = character
        searchText += character
    }

    // Backspace from the handwriting sheet — undoes the last appended character.
    func handleHandwritingDeleteBackward() {
        guard searchText.isEmpty == false else { return }
        searchText.removeLast()
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
