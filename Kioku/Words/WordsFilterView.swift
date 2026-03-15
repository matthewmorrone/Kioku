import SwiftUI

// Sheet for filtering the words list by source note and/or list membership, with inline list CRUD.
// Major sections: All toggle, Notes filter section, Lists filter section with CRUD.
struct WordsFilterView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.dismiss) private var dismiss

    @Binding var activeFilterNoteIDs: Set<UUID>
    @Binding var activeFilterListIDs: Set<UUID>

    @State private var isAddingList = false
    @State private var newListName = ""
    @State private var renamingListID: UUID?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                // Clears all active filters across both notes and lists.
                Button {
                    activeFilterNoteIDs.removeAll()
                    activeFilterListIDs.removeAll()
                } label: {
                    HStack {
                        Text("All").foregroundStyle(.primary)
                        Spacer()
                        if activeFilterNoteIDs.isEmpty && activeFilterListIDs.isEmpty {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Notes that have at least one saved word, so the list stays relevant.
                if notesWithSavedWords.isEmpty == false {
                    Section("Notes") {
                        ForEach(notesWithSavedWords) { (note: Note) in
                            noteFilterRow(note)
                        }
                    }
                }

                Section("Lists") {
                    ForEach(wordListsStore.lists) { (list: WordList) in
                        listFilterRow(list)
                    }

                    if isAddingList {
                        TextField("List name", text: $newListName)
                            .onSubmit { commitNewList() }
                    } else {
                        Button {
                            isAddingList = true
                        } label: {
                            Label("New List", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
    }

    // Only notes that have at least one saved word in the store are shown.
    private var notesWithSavedWords: [Note] {
        let noteIDsWithWords = Set(wordsStore.words.flatMap(\.sourceNoteIDs))
        return notesStore.notes.filter { noteIDsWithWords.contains($0.id) }
    }

    // Builds a note filter row with a checkmark toggle.
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
                HStack {
                    Text(list.name).foregroundStyle(.primary)
                    Spacer()
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

    private func toggleNoteFilter(_ noteID: UUID) {
        if activeFilterNoteIDs.contains(noteID) {
            activeFilterNoteIDs.remove(noteID)
        } else {
            activeFilterNoteIDs.insert(noteID)
        }
    }

    private func toggleListFilter(_ listID: UUID) {
        if activeFilterListIDs.contains(listID) {
            activeFilterListIDs.remove(listID)
        } else {
            activeFilterListIDs.insert(listID)
        }
    }

    private func deleteList(_ listID: UUID) {
        activeFilterListIDs.remove(listID)
        wordListsStore.delete(id: listID)
        wordsStore.removeListMembership(listID: listID)
    }

    private func beginRename(_ list: WordList) {
        renamingListID = list.id
        renameText = list.name
    }

    private func commitRename(_ listID: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            wordListsStore.rename(id: listID, name: trimmed)
        }
        renamingListID = nil
        renameText = ""
    }

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
