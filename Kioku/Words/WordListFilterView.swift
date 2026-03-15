import SwiftUI

// Popover for filtering the Words list by word list membership and managing word lists inline.
// Major sections: "All" toggle, per-list toggles with rename/delete, new list creation.
struct WordListFilterView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore

    @Binding var activeFilterListIDs: Set<UUID>

    @State private var newListName = ""
    @State private var isAddingList = false
    @State private var renamingListID: UUID?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                // Clears all active filters so every word is visible.
                Section {
                    Button {
                        activeFilterListIDs.removeAll()
                    } label: {
                        HStack {
                            Text("All")
                            Spacer()
                            if activeFilterListIDs.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Per-list toggle rows with rename and delete context actions.
                Section("Lists") {
                    ForEach(wordListsStore.lists) { list in
                        if renamingListID == list.id {
                            TextField("List name", text: $renameText)
                                .onSubmit {
                                    commitRename(list.id)
                                }
                        } else {
                            Button {
                                toggleFilter(list.id)
                            } label: {
                                HStack {
                                    Text(list.name)
                                    Spacer()
                                    if activeFilterListIDs.contains(list.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
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

                    // Inline name entry for creating a new list.
                    if isAddingList {
                        TextField("List name", text: $newListName)
                            .onSubmit {
                                commitNewList()
                            }
                    }
                }

                // Adds a new list; shows inline field when tapped.
                Section {
                    Button {
                        isAddingList = true
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Filter by List")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // Adds or removes a list id from the active filter set.
    private func toggleFilter(_ listID: UUID) {
        if activeFilterListIDs.contains(listID) {
            activeFilterListIDs.remove(listID)
        } else {
            activeFilterListIDs.insert(listID)
        }
    }

    // Deletes the list and strips its id from all saved words to avoid orphan memberships.
    private func deleteList(_ listID: UUID) {
        activeFilterListIDs.remove(listID)
        wordListsStore.delete(id: listID)
        wordsStore.removeListMembership(listID: listID)
    }

    // Begins inline rename for a list row.
    private func beginRename(_ list: WordList) {
        renamingListID = list.id
        renameText = list.name
    }

    // Commits a rename if the name is non-empty, otherwise cancels.
    private func commitRename(_ listID: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            wordListsStore.rename(id: listID, name: trimmed)
        }
        renamingListID = nil
        renameText = ""
    }

    // Creates a new list from the inline text field and resets the entry state.
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            wordListsStore.create(name: trimmed)
        }
        newListName = ""
        isAddingList = false
    }
}
