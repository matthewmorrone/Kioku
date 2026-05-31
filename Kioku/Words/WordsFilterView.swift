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

    @Binding var activeFilterNoteIDs: Set<UUID>
    @Binding var activeFilterListIDs: Set<UUID>
    // True when the screen shows the saved/favorites list rather than the lookup history.
    // History is the showSavedWords == false default.
    @Binding var showSavedWords: Bool
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

    // The items inside the "Show" dropdown: Favorites first, then notes, then list submenus,
    // then "New List…" last. Active scope carries a checkmark; tapping it again clears to History.
    @ViewBuilder
    private var scopeMenuContent: some View {
        Button { tapFavorites() } label: {
            Label("Favorites", systemImage: isFavoritesScope ? "checkmark" : "star.fill")
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

    // Favorites is active when showing saved words with no note/list narrowing.
    private var isFavoritesScope: Bool {
        showSavedWords && activeFilterNoteIDs.isEmpty && activeFilterListIDs.isEmpty
    }

    // Label shown on the collapsed dropdown — the one thing currently displayed.
    private var currentScopeLabel: String {
        if showSavedWords == false { return "History" }
        if let noteID = activeFilterNoteIDs.first,
           let note = notesStore.note(withID: noteID) {
            return resolvedTitle(for: note)
        }
        if let listID = activeFilterListIDs.first,
           let list = wordListsStore.lists.first(where: { $0.id == listID }) {
            return list.name
        }
        return "Favorites"
    }

    // MARK: - Scope selection (single-value; tapping the active scope returns to History)

    // Toggles Favorites; when already active, falls back to the History default.
    private func tapFavorites() {
        if isFavoritesScope { selectHistory() } else { selectFavorites() }
    }

    // Toggles a note filter; re-tapping the active note returns to History.
    private func tapNote(_ noteID: UUID) {
        if activeFilterNoteIDs.contains(noteID) { selectHistory() } else { selectNote(noteID) }
    }

    // Toggles a list filter; re-tapping the active list returns to History.
    private func tapList(_ listID: UUID) {
        if activeFilterListIDs.contains(listID) { selectHistory() } else { selectList(listID) }
    }

    // Returns to the History default — the no-scope-selected state.
    private func selectHistory() {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        showSavedWords = false
    }

    // Shows all favorites with no note/list narrowing.
    private func selectFavorites() {
        activeFilterNoteIDs = []
        activeFilterListIDs = []
        showSavedWords = true
    }

    // Filters the saved view to a single source note.
    private func selectNote(_ noteID: UUID) {
        activeFilterNoteIDs = [noteID]
        activeFilterListIDs = []
        showSavedWords = true
    }

    // Filters the saved view to a single word list.
    private func selectList(_ listID: UUID) {
        activeFilterListIDs = [listID]
        activeFilterNoteIDs = []
        showSavedWords = true
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
