import SwiftUI

// Filter sheet: a single-value "Show" dropdown plus a "Sort" dropdown. The Show menu picks
// the one thing the Words screen displays — Favorites, a source note, or a word list —
// with "New List…" as the last item. History is the default (nothing selected), so it's not
// an explicit option: un-picking the active scope (tap the checked item again) returns to it.
// Each list is a submenu carrying its own Show/Rename/Reorder/Delete actions, since a menu
// row can't be long-pressed.
struct WordsFilterView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var reviewStore: ReviewStore

    @Binding var activeFilterNoteIDs: Set<UUID>
    @Binding var activeFilterListIDs: Set<UUID>
    @Binding var statScope: WordsStatScope
    // Active JLPT-level scope (N-number 5…1) or nil. Single-value like the other scopes.
    @Binding var jlptLevel: Int?
    // True when the screen shows the saved/favorites list rather than the lookup history.
    // History is the showSavedWords == false default.
    @Binding var showSavedWords: Bool
    // True when the screen shows the typed-query Recent Searches scope. Mutually exclusive
    // with Favorites/note/list/History.
    @Binding var showRecentSearches: Bool
    @Binding var sortOrder: WordsSortOrder

    @State private var newListName = ""
    @State private var renameText = ""
    @State private var renamingListID: UUID?
    @State private var isNewListAlertPresented = false
    @State private var isRenameAlertPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        scopeMenuContent
                    } label: {
                        HStack {
                            Text("Show")
                            Spacer()
                            Text(currentScopeLabel).foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                }

                Section {
                    Picker(selection: $sortOrder) {
                        ForEach(WordsSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    } label: {
                        Text("Sort")
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("Show")
            .navigationBarTitleDisplayMode(.inline)
            .alert("New List", isPresented: $isNewListAlertPresented) {
                TextField("List name", text: $newListName)
                Button("Create", action: commitNewList)
                Button("Cancel", role: .cancel) { newListName = "" }
            }
            .alert("Rename List", isPresented: $isRenameAlertPresented) {
                TextField("List name", text: $renameText)
                Button("Save") { if let id = renamingListID { commitRename(id) } }
                Button("Cancel", role: .cancel) { renamingListID = nil; renameText = "" }
            }
        }
    }

    // MARK: - Dropdown content

    // The items inside the "Show" dropdown: Favorites first, then stat scopes, then notes,
    // then list submenus, then "New List…" last. Active scope carries a checkmark; tapping it again clears to History.
    @ViewBuilder
    private var scopeMenuContent: some View {
        Button { tapFavorites() } label: {
            Label("Favorites", systemImage: isFavoritesScope ? "checkmark" : "star.fill")
        }

        Button { tapStatScope(.markedWrong) } label: {
            let active = statScope == .markedWrong
            Label(markedWrongLabel, systemImage: active ? "checkmark" : "xmark.circle")
        }

        Button { tapStatScope(.dueForReview) } label: {
            let active = statScope == .dueForReview
            Label(dueForReviewLabel, systemImage: active ? "checkmark" : "clock")
        }

        Button { tapStatScope(.neverReviewed) } label: {
            let active = statScope == .neverReviewed
            Label(neverReviewedLabel, systemImage: active ? "checkmark" : "circle.dashed")
        }

        Button { tapStatScope(.learned) } label: {
            let active = statScope == .learned
            Label(learnedLabel, systemImage: active ? "checkmark" : "checkmark.circle")
        }

        Button { tapStatScope(.notLearned) } label: {
            let active = statScope == .notLearned
            Label(notLearnedLabel, systemImage: active ? "checkmark" : "questionmark.circle")
        }

        Button { tapRecentSearches() } label: {
            Label("Recent Searches", systemImage: showRecentSearches ? "checkmark" : "magnifyingglass")
        }

        // JLPT proficiency level (N5 easiest … N1 hardest). Single-value, nested so it doesn't
        // crowd the top-level list. Levels are unofficial estimates; only saved words with a
        // known level appear. Re-tapping the active level clears back to History.
        Menu {
            // N-numbers descend 5→1 so the menu reads N5 (easiest) first.
            ForEach(Array(stride(from: 5, through: 1, by: -1)), id: \.self) { level in
                Button { tapJLPT(level) } label: {
                    Label("N\(level)", systemImage: jlptLevel == level ? "checkmark" : "graduationcap")
                }
            }
        } label: {
            Label(jlptLevel == nil ? "JLPT Level" : "JLPT N\(jlptLevel ?? 0)",
                  systemImage: jlptLevel == nil ? "graduationcap" : "checkmark")
        }

        ForEach(notesWithSavedWords) { (note: Note) in
            Button { tapNote(note.id) } label: {
                Label(resolvedTitle(for: note),
                      systemImage: activeFilterNoteIDs.contains(note.id) ? "checkmark" : "doc.text")
            }
        }

        ForEach(Array(wordListsStore.lists.enumerated()), id: \.element.id) { index, list in
            Menu {
                Button { tapList(list.id) } label: {
                    let active = activeFilterListIDs.contains(list.id)
                    Label(active ? "Hide" : "Show", systemImage: active ? "eye.slash" : "eye")
                }
                Button { beginRename(list) } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                if index > 0 {
                    Button { moveList(from: index, to: index - 1) } label: {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                }
                if index < wordListsStore.lists.count - 1 {
                    Button { moveList(from: index, to: index + 2) } label: {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                }
                Button(role: .destructive) { deleteList(list.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Label("\(list.name)  (\(wordCount(for: list.id)))",
                      systemImage: activeFilterListIDs.contains(list.id) ? "checkmark" : "folder")
            }
        }

        Divider()

        Button { isNewListAlertPresented = true } label: {
            Label("New List…", systemImage: "square.and.pencil")
        }
    }

    // MARK: - Current scope

    // Favorites is active when showing saved words with no note/list/stat/JLPT narrowing.
    private var isFavoritesScope: Bool {
        showSavedWords && activeFilterNoteIDs.isEmpty && activeFilterListIDs.isEmpty
            && statScope == .none && jlptLevel == nil
    }

    // Label shown on the collapsed dropdown — the one thing currently displayed.
    private var currentScopeLabel: String {
        if showRecentSearches { return "Recent Searches" }
        if showSavedWords == false { return "History" }
        if let jlptLevel { return "JLPT N\(jlptLevel)" }
        if let noteID = activeFilterNoteIDs.first,
           let note = notesStore.note(withID: noteID) {
            return resolvedTitle(for: note)
        }
        if let listID = activeFilterListIDs.first,
           let list = wordListsStore.lists.first(where: { $0.id == listID }) {
            return list.name
        }
        switch statScope {
        case .markedWrong:   return "Marked Wrong"
        case .dueForReview:  return "Due for Review"
        case .neverReviewed: return "Never Reviewed"
        case .learned:       return "Learned"
        case .notLearned:    return "Not Learned"
        case .none:          return "Favorites"
        }
    }

    // Badge labels showing counts for each stat scope option.
    private var markedWrongLabel: String {
        let count = wordsStore.words.filter { reviewStore.markedWrong.contains($0.canonicalEntryID) }.count
        return count > 0 ? "Marked Wrong (\(count))" : "Marked Wrong"
    }

    private var dueForReviewLabel: String {
        let count = wordsStore.words.filter { reviewStore.isDue(id: $0.canonicalEntryID) }.count
        return "Due for Review (\(count))"
    }

    private var neverReviewedLabel: String {
        let count = wordsStore.words.filter { reviewStore.stats[$0.canonicalEntryID] == nil }.count
        return count > 0 ? "Never Reviewed (\(count))" : "Never Reviewed"
    }

    private var learnedLabel: String {
        let count = wordsStore.words.filter { reviewStore.isLearned(id: $0.canonicalEntryID) }.count
        return count > 0 ? "Learned (\(count))" : "Learned"
    }

    private var notLearnedLabel: String {
        let count = wordsStore.words.filter { reviewStore.isNotLearned(id: $0.canonicalEntryID) }.count
        return count > 0 ? "Not Learned (\(count))" : "Not Learned"
    }

    // MARK: - Scope selection (single-value; tapping the active scope returns to History)

    // Toggles Favorites; when already active, falls back to the History default.
    private func tapFavorites() {
        if isFavoritesScope { selectHistory() } else { selectFavorites() }
    }

    // Toggles a stat scope; re-tapping the active one returns to History.
    private func tapStatScope(_ scope: WordsStatScope) {
        if statScope == scope { selectHistory() } else { selectStatScope(scope) }
    }

    // Toggles a note filter; re-tapping the active note returns to History.
    private func tapNote(_ noteID: UUID) {
        if activeFilterNoteIDs.contains(noteID) { selectHistory() } else { selectNote(noteID) }
    }

    // Toggles a list filter; re-tapping the active list returns to History.
    private func tapList(_ listID: UUID) {
        if activeFilterListIDs.contains(listID) { selectHistory() } else { selectList(listID) }
    }

    // Toggles the Recent Searches scope; re-tapping it returns to History.
    private func tapRecentSearches() {
        if showRecentSearches { selectHistory() } else { selectRecentSearches() }
    }

    // Returns to the History default — the no-scope-selected state.
    private func selectHistory() {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        statScope = .none
        showSavedWords = false
        showRecentSearches = false
        jlptLevel = nil
    }

    // Shows all favorites with no note/list/stat narrowing.
    private func selectFavorites() {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        statScope = .none
        showSavedWords = true
        showRecentSearches = false
        jlptLevel = nil
    }

    // Filters the saved view to a stat-based scope.
    private func selectStatScope(_ scope: WordsStatScope) {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        statScope = scope
        showSavedWords = true
        showRecentSearches = false
        jlptLevel = nil
    }

    // Filters the saved view to a single source note.
    private func selectNote(_ noteID: UUID) {
        activeFilterNoteIDs = [noteID]
        activeFilterListIDs = []
        statScope = .none
        showSavedWords = true
        showRecentSearches = false
        jlptLevel = nil
    }

    // Filters the saved view to a single word list.
    private func selectList(_ listID: UUID) {
        activeFilterListIDs = [listID]
        activeFilterNoteIDs = []
        statScope = .none
        showSavedWords = true
        showRecentSearches = false
        jlptLevel = nil
    }

    // Shows only the typed free-text searches; clears every other scope.
    private func selectRecentSearches() {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        statScope = .none
        showSavedWords = false
        showRecentSearches = true
        jlptLevel = nil
    }

    // Toggles a JLPT-level scope; re-tapping the active level returns to History.
    private func tapJLPT(_ level: Int) {
        if jlptLevel == level { selectHistory() } else { selectJLPT(level) }
    }

    // Filters the saved view to a single JLPT level; clears every other scope.
    private func selectJLPT(_ level: Int) {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        statScope = .none
        showSavedWords = true
        showRecentSearches = false
        jlptLevel = level
    }

    // MARK: - List CRUD

    // Reorders a list within the store; mirrors SwiftUI's onMove(from:to:) index convention.
    private func moveList(from: Int, to: Int) {
        wordListsStore.move(from: IndexSet(integer: from), to: to)
    }

    // Removes list membership from all words and deletes the list from the store.
    private func deleteList(_ listID: UUID) {
        activeFilterListIDs.remove(listID)
        wordListsStore.delete(id: listID)
        wordsStore.removeListMembership(listID: listID)
    }

    // Seeds the rename field and opens the rename alert for the given list.
    private func beginRename(_ list: WordList) {
        renamingListID = list.id
        renameText = list.name
        isRenameAlertPresented = true
    }

    // Persists the trimmed rename text and clears rename state.
    private func commitRename(_ listID: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            wordListsStore.rename(id: listID, name: trimmed)
        }
        renamingListID = nil
        renameText = ""
    }

    // Creates a new word list and immediately selects it as the active scope.
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let newID = wordListsStore.create(name: trimmed)
            selectList(newID)
        }
        newListName = ""
    }

    // MARK: - Data helpers

    // Counts how many saved words belong to a given list — shown as a trailing badge.
    private func wordCount(for listID: UUID) -> Int {
        wordsStore.words.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
    }

    // Only notes that have at least one saved word in the store are shown.
    private var notesWithSavedWords: [Note] {
        let noteIDsWithWords = Set(wordsStore.words.flatMap(\.sourceNoteIDs))
        return notesStore.notes.filter { noteIDsWithWords.contains($0.id) }
    }

    // Falls back to "Untitled Note" when the note title is blank.
    private func resolvedTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }
}
