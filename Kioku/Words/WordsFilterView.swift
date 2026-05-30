import SwiftUI

// Sheet for filtering the words list by source note and/or list membership, with inline list CRUD.
// Major sections: Notes filter section, Lists filter section with CRUD.
// When nothing is selected all words are shown.
struct WordsFilterView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.dismiss) private var dismiss

    @Binding var activeFilterNoteIDs: Set<UUID>
    @Binding var activeFilterListIDs: Set<UUID>
    // True when the Words screen should be displaying the saved/favorites list rather
    // than the lookup history. Driven by the toggle row at the top of this sheet so
    // "show me my favorites" is one tap away without leaving the filter context.
    @Binding var showSavedWords: Bool
    // Sort order applied to whichever list is currently being shown (saved vs history).
    // The parent owns the storage; this sheet just toggles between options.
    @Binding var sortOrder: WordsSortOrder

    @State private var isAddingList = false
    @State private var newListName = ""
    @State private var renamingListID: UUID?
    @State private var renameText = ""
    @State private var listsEditMode: EditMode = .inactive

    // True when any note OR list filter is active. Drives the Favorites row visibility:
    // a note/list filter is inherently a narrowing of the saved-words view, so the
    // Favorites toggle becomes redundant (and contradictory if turned off) while one
    // is on. Hiding makes the relationship visually mutex without disabling controls.
    private var anyNoteOrListSelected: Bool {
        activeFilterNoteIDs.isEmpty == false || activeFilterListIDs.isEmpty == false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    savedFilterRow
                }

                // Notes that have at least one saved word, so the list stays relevant.
                if notesWithSavedWords.isEmpty == false {
                    Section {
                        ForEach(notesWithSavedWords) { (note: Note) in
                            noteFilterRow(note)
                        }
                    }
                }

                Section {
                    ForEach(wordListsStore.lists) { (list: WordList) in
                        listFilterRow(list)
                    }
                    .onMove { source, destination in
                        wordListsStore.move(from: source, to: destination)
                    }

                    if isAddingList {
                        TextField("List name", text: $newListName)
                            .onSubmit { commitNewList() }
                    } else if listsEditMode != .active {
                        Button {
                            isAddingList = true
                        } label: {
                            Label("New List", systemImage: "square.and.pencil")
                        }
                    }
                }

                // Sort control sits below the filter sections — last because it shapes
                // *how* the filtered set is ordered, after you've decided *what* to show.
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
            .environment(\.editMode, $listsEditMode)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if wordListsStore.lists.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation {
                                listsEditMode = listsEditMode == .active ? .inactive : .active
                            }
                        } label: {
                            Image(systemName: listsEditMode == .active ? "checkmark.circle" : "arrow.up.arrow.down")
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel(listsEditMode == .active ? "Done Reordering" : "Reorder Lists")
                    }
                }
            }
        }
    }

    // Counts how many saved words belong to a given list — shown as a trailing badge on each row.
    private func wordCount(for listID: UUID) -> Int {
        wordsStore.words.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
    }

    // Only notes that have at least one saved word in the store are shown.
    private var notesWithSavedWords: [Note] {
        let noteIDsWithWords = Set(wordsStore.words.flatMap(\.sourceNoteIDs))
        return notesStore.notes.filter { noteIDsWithWords.contains($0.id) }
    }

    // Favorites toggle row — same visual pattern as noteFilterRow so the sheet
    // reads as a coherent list of selectable scopes. Leading star icon visually
    // anchors the row to the same star used on individual word rows.
    @ViewBuilder
    private var savedFilterRow: some View {
        Button {
            showSavedWords.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(Color.yellow)
                Text("Favorites").foregroundStyle(.primary)
                Spacer()
                // Checkmark suppressed while any note/list filter is active — the filter
                // is the dominant selector, Favorites is mutex-implied. Row stays visible
                // and tappable so the user can flip it for when filters are cleared.
                if showSavedWords && anyNoteOrListSelected == false {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Builds a note filter row that toggles the note filter on/off.
    @ViewBuilder
    private func noteFilterRow(_ note: Note) -> some View {
        Button {
            toggleNoteFilter(note.id)
        } label: {
            HStack {
                Text(resolvedTitle(for: note)).foregroundStyle(.primary)
                Spacer()
                if activeFilterNoteIDs.contains(note.id) {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Builds a list filter row with checkmark toggle and rename/delete swipe actions.
    @ViewBuilder
    private func listFilterRow(_ list: WordList) -> some View {
        if renamingListID == list.id {
            TextField("List name", text: $renameText)
                .onSubmit { commitRename(list.id) }
        } else {
            Button {
                toggleListFilter(list.id)
            } label: {
                HStack(spacing: 8) {
                    Text(list.name).foregroundStyle(.primary)
                    Spacer()
                    Text("\(wordCount(for: list.id))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if activeFilterListIDs.contains(list.id) {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    deleteList(list.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    beginRename(list)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
    }

    // Adds or removes a note ID from the active filter set. Selecting any note auto-
    // flips the Favorites toggle on — note filters only narrow the saved-words view,
    // so toggling one while History is showing would silently do nothing otherwise.
    private func toggleNoteFilter(_ noteID: UUID) {
        if activeFilterNoteIDs.contains(noteID) {
            activeFilterNoteIDs.remove(noteID)
        } else {
            activeFilterNoteIDs.insert(noteID)
            showSavedWords = true
        }
    }

    // Adds or removes a word list ID from the active filter set. Selecting any list
    // auto-flips the Favorites toggle on (same rationale as toggleNoteFilter).
    private func toggleListFilter(_ listID: UUID) {
        if activeFilterListIDs.contains(listID) {
            activeFilterListIDs.remove(listID)
        } else {
            activeFilterListIDs.insert(listID)
            showSavedWords = true
        }
    }

    // Removes list membership from all words and deletes the list from the store.
    private func deleteList(_ listID: UUID) {
        activeFilterListIDs.remove(listID)
        wordListsStore.delete(id: listID)
        wordsStore.removeListMembership(listID: listID)
    }

    // Populates the rename text field and marks the given list as being renamed.
    private func beginRename(_ list: WordList) {
        renamingListID = list.id
        renameText = list.name
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

    // Creates a new word list from the trimmed name input and clears the field.
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            wordListsStore.create(name: trimmed)
        }
        newListName = ""
        isAddingList = false
    }

    // Falls back to "Untitled Note" when the note title is blank.
    private func resolvedTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }
}
