import SwiftUI

// Dedicated list-CRUD screen, reached from WordsFilterView's "Manage Lists…" row. Split out
// so the Show menu (WordsFilterView.listRow) can stay a pure filter, mirroring noteRow —
// rename/reorder/delete/create all live here instead of buried in per-list submenus.
struct ManageWordListsView: View {
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var savedKanjiStore: SavedKanjiStore

    // Mirrors WordsFilterView's active list filter so deleting the currently-filtered list
    // clears it (rather than leaving a dead UUID selected) and creating a new list selects
    // it as the active filter, same as the old inline-menu behavior.
    @Binding var activeFilterListIDs: Set<UUID>
    @Binding var showSavedWords: Bool

    @State private var newListName = ""
    @State private var isNewListAlertPresented = false
    @State private var renameText = ""
    @State private var renamingListID: UUID?
    @State private var isRenameAlertPresented = false

    var body: some View {
        List {
            Section {
                ForEach(wordListsStore.lists) { list in
                    HStack {
                        Text(list.name)
                        Spacer()
                        Text("\(wordCount(for: list.id))")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteList(list.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { beginRename(list) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onMove(perform: moveList)
            } footer: {
                if wordListsStore.lists.isEmpty == false {
                    Text("Swipe a list to rename or delete it. Drag to reorder.")
                }
            }

            Section {
                Button { isNewListAlertPresented = true } label: {
                    Label("New List…", systemImage: "square.and.pencil")
                }
            }
        }
        .navigationTitle("Manage Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
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

    // MARK: - List CRUD

    private func moveList(from source: IndexSet, to destination: Int) {
        wordListsStore.move(from: source, to: destination)
    }

    // Removes list membership from all saved words AND saved kanji, then deletes the list
    // from the store. Both record types share the same WordList ids, so both stores need to
    // be cleaned up — otherwise a kanji's wordListIDs could carry a dead UUID forever.
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

    // Creates a new word list from the trimmed alert text field, if non-empty, and — matching
    // the old inline-menu behavior — immediately selects it as the active list filter and
    // switches the Words tab to Favorites (narrowing filters only apply to saved words).
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let newID = wordListsStore.create(name: trimmed)
            activeFilterListIDs = [newID]
            showSavedWords = true
        }
        newListName = ""
    }

    // MARK: - Data helpers

    // Counts saved members of a given list — words + kanji. Both record types share the same
    // WordList ids (see SavedKanji.wordListIDs), so a kanji-only list registers a non-zero
    // count instead of the misleading 0 we'd get from counting only SavedWord entries.
    private func wordCount(for listID: UUID) -> Int {
        let words = wordsStore.words.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        let kanji = savedKanjiStore.kanji.reduce(0) { $0 + ($1.wordListIDs.contains(listID) ? 1 : 0) }
        return words + kanji
    }
}
