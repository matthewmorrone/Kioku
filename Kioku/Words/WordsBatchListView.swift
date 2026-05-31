import SwiftUI

// Sheet for bulk-managing word-list membership for the current multi-selection.
//
// Three modes, chosen by a segmented picker at the top:
//   • Add / Remove — tap a list to toggle the whole selection in or out of it
//     (tri-state icon shows all / some / none currently in that list).
//   • Move         — tap a target list to add the selection there AND remove it from
//     the list currently being viewed (the "source"). Only available when filtered to
//     exactly one list, so the source is unambiguous; the source is hidden as a target.
//   • Copy         — tap a target list to add the selection there, leaving every existing
//     membership (including the source) intact.
//
// Move/Copy only appear when a single source list is in context. Without a source, "Move"
// has no well-defined origin and "Copy" is identical to Add, so the picker is hidden and
// the sheet falls back to plain Add/Remove toggling.
struct WordsBatchListView: View {
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @Environment(\.dismiss) private var dismiss

    let selectedWordIDs: Set<Int64>
    // The single list currently being viewed (active list filter), if exactly one is on.
    // Enables Move (remove-from-source) and is excluded from the Move target list.
    var sourceListID: UUID? = nil
    // Surface text per selected id, used to materialize a SavedWord for any History-only
    // word the moment it's added to a list — putting a word in a list implies saving it.
    var surfaces: [Int64: String] = [:]

    enum Mode: Hashable { case toggle, move, copy }

    @State private var mode: Mode = .toggle
    @State private var isAddingList = false
    @State private var newListName = ""

    private var sourceList: WordList? {
        guard let sourceListID else { return nil }
        return wordListsStore.lists.first { $0.id == sourceListID }
    }

    // Lists shown as tap targets. In Move mode the source list is removed — you can't move
    // words out of a list into the same list.
    private var targetLists: [WordList] {
        if mode == .move, let sourceListID {
            return wordListsStore.lists.filter { $0.id != sourceListID }
        }
        return wordListsStore.lists
    }

    var body: some View {
        NavigationStack {
            List {
                if sourceList != nil {
                    Section {
                        Picker("Action", selection: $mode) {
                            Text("Add / Remove").tag(Mode.toggle)
                            Text("Move").tag(Mode.move)
                            Text("Copy").tag(Mode.copy)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(modeFooter)
                    }
                }

                Section {
                    ForEach(targetLists) { (list: WordList) in
                        Button {
                            handleTap(list.id)
                        } label: {
                            HStack {
                                Text(list.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: trailingIcon(for: list.id))
                                    .foregroundStyle(trailingTint(for: list.id))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Inline new-list creation — creates the list and immediately applies the
                    // current mode's action (add / move-into / copy-into) to all selected words.
                    // An explicit Add button sits beside the field because a TextField only
                    // fires .onSubmit on the keyboard Return — without it, typing a name and
                    // tapping Done (or a list row) would silently discard the list.
                    if isAddingList {
                        HStack {
                            TextField("List name", text: $newListName)
                                .submitLabel(.done)
                                .onSubmit { commitNewList() }
                            Button("Add") { commitNewList() }
                                .buttonStyle(.borderless)
                                .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        Button {
                            isAddingList = true
                        } label: {
                            Label("New List", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        commitNewList()
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Done")
                }
            }
            // Backstop for swipe-to-dismiss: commit a half-typed list name rather than lose it.
            .onDisappear { commitNewList() }
        }
    }

    private var title: String {
        "\(selectedWordIDs.count) Word\(selectedWordIDs.count == 1 ? "" : "s")"
    }

    private var modeFooter: String {
        switch mode {
        case .toggle:
            return "Tap a list to add or remove the selected words."
        case .move:
            return "Tap a list to move the selected words there, removing them from “\(sourceList?.name ?? "")”."
        case .copy:
            return "Tap a list to copy the selected words there, keeping their current lists."
        }
    }

    // MARK: - Tap handling

    private func handleTap(_ listID: UUID) {
        // Any add path may include History-only words that aren't saved yet — materialize
        // them first so addToList has a SavedWord to attach. No-op when all are saved, and
        // the pure-remove branch below only ever touches already-saved words.
        ensureSaved()
        switch mode {
        case .toggle:
            if membershipState(for: listID) == .all {
                wordsStore.removeFromList(wordIDs: selectedWordIDs, listID: listID)
            } else {
                wordsStore.addToList(wordIDs: selectedWordIDs, listID: listID)
            }
        case .copy:
            wordsStore.addToList(wordIDs: selectedWordIDs, listID: listID)
        case .move:
            wordsStore.addToList(wordIDs: selectedWordIDs, listID: listID)
            if let sourceListID, sourceListID != listID {
                wordsStore.removeFromList(wordIDs: selectedWordIDs, listID: sourceListID)
            }
        }
    }

    // Saves any selected words not yet in WordsStore (History-only rows), using the surface
    // text passed in. Senses start empty — the detail sheet fills them when the user opens
    // the card. One bulk add() so the persist cost is paid once.
    private func ensureSaved() {
        let existing = Set(wordsStore.words.map(\.canonicalEntryID))
        let missing = selectedWordIDs.subtracting(existing)
        guard missing.isEmpty == false else { return }
        let newWords = missing.map { id in
            SavedWord(canonicalEntryID: id, surface: surfaces[id] ?? "")
        }
        wordsStore.add(newWords)
    }

    // Creates a new list, then applies the active mode against it. New lists never start as
    // a Move source, so Move here behaves the same as Copy (add to the new list) plus the
    // source removal that Move always performs.
    private func commitNewList() {
        let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isAddingList = false
            return
        }
        ensureSaved()
        let newID = wordListsStore.create(name: trimmed)
        wordsStore.addToList(wordIDs: selectedWordIDs, listID: newID)
        if mode == .move, let sourceListID {
            wordsStore.removeFromList(wordIDs: selectedWordIDs, listID: sourceListID)
        }
        newListName = ""
        isAddingList = false
    }

    // MARK: - Membership display

    private enum MembershipState { case all, some, none }

    // Returns whether all, some, or none of the currently selected words belong to the given list.
    private func membershipState(for listID: UUID) -> MembershipState {
        let selectedWords = wordsStore.words.filter { selectedWordIDs.contains($0.canonicalEntryID) }
        let memberCount = selectedWords.filter { $0.wordListIDs.contains(listID) }.count
        if memberCount == 0 { return .none }
        if memberCount == selectedWords.count { return .all }
        return .some
    }

    // In Add/Remove mode the trailing icon reflects tri-state membership; in Move/Copy mode
    // it's a directional affordance (the row is an action, not a toggle).
    private func trailingIcon(for listID: UUID) -> String {
        switch mode {
        case .toggle:
            switch membershipState(for: listID) {
            case .all:  return "checkmark.circle.fill"
            case .some: return "minus.circle.fill"
            case .none: return "circle"
            }
        case .move: return "arrow.right.circle"
        case .copy: return "plus.circle"
        }
    }

    // Dims the toggle icon to secondary only for lists the selection isn't in yet; every
    // active/affordance state (member, move, copy) uses the accent color.
    private func trailingTint(for listID: UUID) -> Color {
        if mode == .toggle, membershipState(for: listID) == .none {
            return .secondary
        }
        return .accentColor
    }
}
