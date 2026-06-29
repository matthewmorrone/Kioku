import SwiftUI

// Data-derivation helpers and row actions for the Words screen: filtered/sorted word
// and history collections, the shared selection model, save/unsave, lemma re-pointing,
// and the kanji-discovery sheet callbacks. Extracted from WordsView so the primary
// file stays under the line-count invariant.
extension WordsView {
    // MARK: - Helpers

    // True when any filter is active across notes, lists, stat scope, or JLPT level.
    var isFilterActive: Bool {
        !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty || statScope != .none || jlptLevel != nil
    }

    // Returns saved kanji filtered by the same note/list scope as visibleWords, sorted
    // newest-first by savedAt. Kanji have no review stats yet, so the statScope and
    // jlptLevel filters don't apply — they pass through unfiltered to the section.
    var visibleSavedKanji: [SavedKanji] {
        var filtered = savedKanjiStore.kanji
        if !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty {
            filtered = filtered.filter { kanji in
                let matchesNote = activeFilterNoteIDs.isEmpty || activeFilterNoteIDs.contains { kanji.sourceNoteIDs.contains($0) }
                let matchesList = activeFilterListIDs.isEmpty || activeFilterListIDs.contains { kanji.wordListIDs.contains($0) }
                return matchesNote && matchesList
            }
        }
        return filtered.sorted { $0.savedAt > $1.savedAt }
    }

    // Returns saved words filtered by active note/list/stat selection and sorted by the current saved sort order.
    var visibleWords: [SavedWord] {
        var filtered = wordsStore.words

        if !activeFilterNoteIDs.isEmpty || !activeFilterListIDs.isEmpty {
            filtered = filtered.filter { word in
                let matchesNote = activeFilterNoteIDs.isEmpty || activeFilterNoteIDs.contains { word.sourceNoteIDs.contains($0) }
                let matchesList = activeFilterListIDs.isEmpty || activeFilterListIDs.contains { word.wordListIDs.contains($0) }
                return matchesNote && matchesList
            }
        }

        switch statScope {
        case .none:
            break
        case .markedWrong:
            filtered = filtered.filter { reviewStore.markedWrong.contains($0.canonicalEntryID) }
        case .dueForReview:
            filtered = filtered.filter { reviewStore.isDue(id: $0.canonicalEntryID) }
        case .neverReviewed:
            filtered = filtered.filter { reviewStore.stats[$0.canonicalEntryID] == nil }
        case .learned:
            filtered = filtered.filter { reviewStore.isLearned(id: $0.canonicalEntryID) }
        case .notLearned:
            filtered = filtered.filter { reviewStore.isNotLearned(id: $0.canonicalEntryID) }
        }

        if let jlptLevel {
            filtered = filtered.filter { dictionaryStore?.jlptLevel(for: $0.canonicalEntryID) == jlptLevel }
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
        case .mostWrong, .worstAccuracy, .mostReviewed:
            // Review-stat sort orders are Saved-tab only; history has no per-entry review stats to
            // rank by, so fall back to newest-first. (Resolves a non-exhaustive switch on main's tip:
            // these cases were added to WordsSortOrder + sorted(_:by:) without updating this switch.)
            return historyStore.entries.sorted { $0.lookedUpAt > $1.lookedUpAt }
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

    // The saved-kanji literals selectable on the current tab. Kanji only appear on the Saved
    // tab (never History or live search), so this is empty everywhere else — mirroring how
    // selectableWordIDs is gated by tab. Drives Select All and the batch-remove count for
    // kanji, which ride a parallel String selection set since List(selection:) is Int64-keyed.
    var selectableKanjiLiterals: [String] {
        if showRecentSearches { return [] }
        if searchText.isEmpty && activeTab == .saved {
            return visibleSavedKanji.map(\.literal)
        }
        return []
    }

    // Combined count of selected words + kanji, for the batch-remove label and dialog title.
    var batchSelectionCount: Int { selectedWordIDs.count + selectedKanjiLiterals.count }

    // Title for the batch-remove confirmation. "item" rather than "word" because the selection
    // can now mix saved words and saved kanji.
    var batchRemoveTitle: String {
        "Remove \(batchSelectionCount) item\(batchSelectionCount == 1 ? "" : "s")?"
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
        case .mostWrong:
            return words.sorted {
                (reviewStore.stats[$0.canonicalEntryID]?.again ?? 0) >
                (reviewStore.stats[$1.canonicalEntryID]?.again ?? 0)
            }
        case .worstAccuracy:
            // Words with reviews sort by accuracy ascending (worst first).
            // Unreviewed words (nil accuracy) go at the end.
            return words.sorted { lhs, rhs in
                let la = reviewStore.stats[lhs.canonicalEntryID]?.accuracy
                let ra = reviewStore.stats[rhs.canonicalEntryID]?.accuracy
                switch (la, ra) {
                case (nil, nil): return lhs.surface < rhs.surface
                case (nil, _):   return false
                case (_, nil):   return true
                case let (l?, r?): return l < r
                }
            }
        case .mostReviewed:
            return words.sorted {
                (reviewStore.stats[$0.canonicalEntryID]?.total ?? 0) >
                (reviewStore.stats[$1.canonicalEntryID]?.total ?? 0)
            }
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

    // Creates (or reuses) a regular WordList named "Animated Kanji" and adds
    // every literal from KanjiDecoration.animatedKanjiCategories to it as a
    // SavedKanji member. Idempotent — running twice doesn't create a second
    // list, and kanji already saved have their list membership unioned rather
    // than duplicated. Surfaces the list in the Saved tab's Kanji section once
    // the user filters by it.
    func populateAnimatedKanjiList() {
        let listName = "Animated Kanji"
        let listID: UUID = wordListsStore.lists.first { $0.name == listName }?.id
            ?? wordListsStore.create(name: listName)
        for (_, literals) in KanjiDecoration.animatedKanjiCategories {
            for literal in literals {
                if savedKanjiStore.contains(literal: literal) {
                    savedKanjiStore.setListMembership(literal: literal, listID: listID, isMember: true)
                } else {
                    savedKanjiStore.save(literal: literal, wordListIDs: [listID])
                }
            }
        }
    }

    // Toggles a word's membership in `listID`, saving the word first if it isn't
    // already saved. Without the save step, `WordsStore.toggleListMembership` is a
    // no-op on unsaved words (it only mutates existing entries) — so adding an
    // unsaved search result to a list silently does nothing without this guard.
    func addOrToggleListMembership(entryID: Int64, surface: String, materialized: DictionaryEntry?, listID: UUID) {
        if isSavedByID(entryID) == false {
            toggleSaveWord(entryID: entryID, surface: surface, materialized: materialized)
        }
        wordsStore.toggleListMembership(wordID: entryID, listID: listID)
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

    // Single emit handler shared by radical and handwriting input — both modal and inline
    // (JapaneseInputTextField) routes call this so multi-character composition works the same
    // way everywhere. The sheet stays open; users close it explicitly (modal: Close button;
    // inline: tap ⌨ on the mode bar).
    func handleEmitToSearch(_ emitted: String) {
        searchText += emitted
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
