import SwiftUI

// Filter sheet for the Words screen. History/Favorites is the one mutually-exclusive "base
// view" choice (a 2-way segmented control, since exactly one is always showing) — History
// includes both word lookups and typed free-text searches together, newest first. Everything
// else — Review Status, JLPT Level, Note, List, plus Sort and Kanji below — is an independent,
// composable narrowing filter with its own row/menu, mirroring how Sort and Kanji already
// worked: picking a Review Status AND a Note AND a List all combine (see
// WordsView+Actions.visibleWords, which already ANDs them together). Picking any of these
// narrowing filters switches the base view to Favorites, since they only apply to saved words.
struct WordsFilterView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var savedKanjiStore: SavedKanjiStore
    @EnvironmentObject private var notesStore: NotesStore

    @Binding var activeFilterNoteIDs: Set<UUID>
    @Binding var activeFilterListIDs: Set<UUID>
    @Binding var statScope: WordsStatScope
    // Active JLPT-level scope (N-number 5…1) or nil. Single-value like the other narrowing filters.
    @Binding var jlptLevel: Int?
    // True when the screen shows the saved/favorites list rather than the lookup history.
    @Binding var showSavedWords: Bool
    @Binding var sortOrder: WordsSortOrder
    // Orthogonal kanji-content refinement; composes with every other filter rather than
    // replacing them. Off by default (pure-kana only).
    @Binding var showKanji: Bool

    @State private var newListName = ""
    @State private var renameText = ""
    @State private var renamingListID: UUID?
    @State private var isNewListAlertPresented = false
    @State private var isRenameAlertPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Base view", selection: $showSavedWords) {
                        Text("History").tag(false)
                        Text("Favorites").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section { reviewStatusRow }
                Section { jlptLevelRow }
                if notesWithSavedWords.isEmpty == false {
                    Section { noteRow }
                }
                Section { listRow }

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

                Section {
                    Toggle("Show Kanji", isOn: $showKanji)
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

    // MARK: - Narrowing filter rows

    private var reviewStatusRow: some View {
        Menu {
            Button { tapStatScope(.markedWrong) } label: {
                Label(markedWrongLabel, systemImage: statScope == .markedWrong ? "checkmark" : "xmark.circle")
            }
            Button { tapStatScope(.dueForReview) } label: {
                Label(dueForReviewLabel, systemImage: statScope == .dueForReview ? "checkmark" : "clock")
            }
            Button { tapStatScope(.neverReviewed) } label: {
                Label(neverReviewedLabel, systemImage: statScope == .neverReviewed ? "checkmark" : "circle.dashed")
            }
            Button { tapStatScope(.learned) } label: {
                Label(learnedLabel, systemImage: statScope == .learned ? "checkmark" : "checkmark.circle")
            }
            Button { tapStatScope(.notLearned) } label: {
                Label(notLearnedLabel, systemImage: statScope == .notLearned ? "checkmark" : "questionmark.circle")
            }
        } label: {
            filterRowLabel(title: "Review Status", value: reviewStatusLabel)
        }
    }

    // JLPT proficiency level (N5 easiest … N1 hardest). Levels are unofficial estimates; only
    // saved words with a known level appear. Re-tapping the active level clears back to "Any".
    private var jlptLevelRow: some View {
        Menu {
            // N-numbers descend 5→1 so the menu reads N5 (easiest) first.
            ForEach(Array(stride(from: 5, through: 1, by: -1)), id: \.self) { level in
                Button { tapJLPT(level) } label: {
                    Label("N\(level)", systemImage: jlptLevel == level ? "checkmark" : "graduationcap")
                }
            }
        } label: {
            filterRowLabel(title: "JLPT Level", value: jlptLevelLabel)
        }
    }

    private var noteRow: some View {
        Menu {
            ForEach(notesWithSavedWords) { (note: Note) in
                Button { tapNote(note.id) } label: {
                    Label(resolvedTitle(for: note),
                          systemImage: activeFilterNoteIDs.contains(note.id) ? "checkmark" : "doc.text")
                }
            }
        } label: {
            filterRowLabel(title: "Note", value: noteLabel)
        }
    }

    // Each list is a submenu carrying its own Show/Rename/Reorder/Delete actions, since a menu
    // row can't be long-pressed.
    private var listRow: some View {
        Menu {
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
        } label: {
            filterRowLabel(title: "List", value: listLabel)
        }
    }

    // Shared row chrome for the narrowing-filter menus above, matching the base-view row's look.
    private func filterRowLabel(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Row value labels

    private var reviewStatusLabel: String {
        switch statScope {
        case .none:          return "Any"
        case .markedWrong:   return "Marked Wrong"
        case .dueForReview:  return "Due for Review"
        case .neverReviewed: return "Never Reviewed"
        case .learned:       return "Learned"
        case .notLearned:    return "Not Learned"
        }
    }

    private var jlptLevelLabel: String {
        jlptLevel.map { "N\($0)" } ?? "Any"
    }

    private var noteLabel: String {
        guard let noteID = activeFilterNoteIDs.first, let note = notesStore.note(withID: noteID) else { return "Any" }
        return resolvedTitle(for: note)
    }

    private var listLabel: String {
        guard let listID = activeFilterListIDs.first,
              let list = wordListsStore.lists.first(where: { $0.id == listID }) else { return "Any" }
        return list.name
    }

    // Badge labels showing counts for each stat scope option.
    private var markedWrongLabel: String {
        let count = wordsStore.words.filter { wordsStore.markedWrong.contains($0.canonicalEntryID) }.count
        return count > 0 ? "Marked Wrong (\(count))" : "Marked Wrong"
    }

    private var dueForReviewLabel: String {
        let count = wordsStore.words.filter { wordsStore.isDueForReview(id: $0.canonicalEntryID) }.count
        return "Due for Review (\(count))"
    }

    private var neverReviewedLabel: String {
        let count = wordsStore.words.filter { wordsStore.stats[$0.canonicalEntryID] == nil }.count
        return count > 0 ? "Never Reviewed (\(count))" : "Never Reviewed"
    }

    private var learnedLabel: String {
        let count = wordsStore.words.filter { wordsStore.isLearned(id: $0.canonicalEntryID) }.count
        return count > 0 ? "Learned (\(count))" : "Learned"
    }

    private var notLearnedLabel: String {
        let count = wordsStore.words.filter { wordsStore.isNotLearned(id: $0.canonicalEntryID) }.count
        return count > 0 ? "Not Learned (\(count))" : "Not Learned"
    }

    // MARK: - Narrowing filter selection (each is independent; re-tapping the active choice clears
    // just that one filter — the others, and the base view, are untouched)

    private func tapStatScope(_ scope: WordsStatScope) {
        statScope = statScope == scope ? .none : scope
        activateFavorites()
    }

    // Toggles a JLPT-level filter; re-tapping the active level clears it.
    private func tapJLPT(_ level: Int) {
        jlptLevel = jlptLevel == level ? nil : level
        activateFavorites()
    }

    // Toggles a note filter; re-tapping the active note clears it.
    private func tapNote(_ noteID: UUID) {
        activeFilterNoteIDs = activeFilterNoteIDs.contains(noteID) ? [] : [noteID]
        activateFavorites()
    }

    // Toggles a list filter; re-tapping the active list clears it.
    private func tapList(_ listID: UUID) {
        activeFilterListIDs = activeFilterListIDs.contains(listID) ? [] : [listID]
        activateFavorites()
    }

    // Narrowing filters only apply to saved words (see WordsView+Actions.visibleWords), so
    // picking one always switches the base view to Favorites.
    private func activateFavorites() {
        showSavedWords = true
    }

    // MARK: - List CRUD

    // Reorders a list within the store; mirrors SwiftUI's onMove(from:to:) index convention.
    private func moveList(from: Int, to: Int) {
        wordListsStore.move(from: IndexSet(integer: from), to: to)
    }

    // Removes list membership from all saved words AND saved kanji, then deletes
    // the list from the store. Both record types share the same WordList ids,
    // so both stores need to be cleaned up — otherwise a kanji's wordListIDs
    // could carry a dead UUID forever.
    private func deleteList(_ listID: UUID) {
        activeFilterListIDs.remove(listID)
        wordListsStore.delete(id: listID)
        wordsStore.removeListMembership(listID: listID)
        savedKanjiStore.removeListMembership(listID: listID)
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

    // Creates a new word list and immediately selects it as the active list filter.
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let newID = wordListsStore.create(name: trimmed)
            activeFilterListIDs = [newID]
            activateFavorites()
        }
        newListName = ""
    }

    // MARK: - Data helpers

    // Counts saved members of a given list — words + kanji. Both record types
    // share the same WordList ids (see SavedKanji.wordListIDs), so a kanji-only
    // list registers a non-zero count instead of the misleading "Animated (0)"
    // we'd get from counting only SavedWord entries.
    private func wordCount(for listID: UUID) -> Int {
        let words = wordsStore.words.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        let kanji = savedKanjiStore.kanji.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        return words + kanji
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
