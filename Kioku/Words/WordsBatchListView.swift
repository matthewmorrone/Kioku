import SwiftUI

// Sheet for adding or removing all selected words from word lists simultaneously.
// Major sections: per-list rows with tri-state membership indicators.
struct WordsBatchListView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @Environment(\.dismiss) private var dismiss

    let selectedWordIDs: Set<Int64>

    @State private var isAddingList = false
    @State private var newListName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(wordListsStore.lists) { (list: WordList) in
                    Button {
                        toggleList(list.id)
                    } label: {
                        HStack {
                            Text(list.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: membershipIcon(for: list.id))
                                .foregroundStyle(membershipState(for: list.id) == .none ? Color.secondary : Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Inline new-list creation — creates the list and immediately adds all selected words to it.
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
            .navigationTitle("Add to List")
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

    // Returns whether all, some, or none of the selected words are in this list.
    private enum MembershipState { case all, some, none }

    // Returns whether all, some, or none of the currently selected words belong to the given list.
    private func membershipState(for listID: UUID) -> MembershipState {
        let selectedWords = wordsStore.words.filter { selectedWordIDs.contains($0.canonicalEntryID) }
        let memberCount = selectedWords.filter { $0.wordListIDs.contains(listID) }.count
        if memberCount == 0 { return .none }
        if memberCount == selectedWords.count { return .all }
        return .some
    }

    // Returns the SF Symbol for the current tri-state: all = filled check, some = minus, none = empty circle.
    private func membershipIcon(for listID: UUID) -> String {
        switch membershipState(for: listID) {
        case .all:  return "checkmark.circle.fill"
        case .some: return "minus.circle.fill"
        case .none: return "circle"
        }
    }

    // Creates a new list from the inline field and immediately adds all selected words to it.
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isAddingList = false
            return
        }
        wordListsStore.create(name: trimmed)
        if let newList = wordListsStore.lists.last {
            wordsStore.addToList(wordIDs: selectedWordIDs, listID: newList.id)
        }
        newListName = ""
        isAddingList = false
    }

    // If all selected words are already in the list, removes them; otherwise adds all.
    private func toggleList(_ listID: UUID) {
        if membershipState(for: listID) == .all {
            wordsStore.removeFromList(wordIDs: selectedWordIDs, listID: listID)
        } else {
            wordsStore.addToList(wordIDs: selectedWordIDs, listID: listID)
        }
    }
}
