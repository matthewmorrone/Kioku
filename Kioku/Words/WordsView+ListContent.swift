import SwiftUI

// List content for the Words screen — the saved-words list, the history list, and the
// individual history-row builder used by the history tab.
extension WordsView {
    // MARK: - List content sections

    @ViewBuilder
    var savedWordsContent: some View {
        if visibleWords.isEmpty {
            Text("No saved words yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(visibleWords, id: \.canonicalEntryID) { savedWord in
                WordRowView(
                    word: savedWord,
                    lists: wordListsStore.lists,
                    onOpenDetails: {
                        guard editMode == .inactive else { return }
                        selectedDetailWord = savedWord
                    },
                    onToggleList: { listID in
                        wordsStore.toggleListMembership(wordID: savedWord.canonicalEntryID, listID: listID)
                    },
                    onRemove: { wordsStore.remove(id: savedWord.canonicalEntryID) }
                )
                .tag(savedWord.canonicalEntryID)
            }
        }
    }

    @ViewBuilder
    var historyContent: some View {
        if historyStore.entries.isEmpty {
            Text("No lookup history yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sortedHistory) { entry in
                historyRow(entry)
                    .tag(entry.canonicalEntryID)
            }
        }
    }

    // Renders one history entry row with swipe-to-delete and a context menu matching the saved-words CRUD pattern.
    @ViewBuilder
    func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.surface)
                .font(.headline)

            Spacer(minLength: 0)

            Button {
                toggleSaveHistory(entry)
            } label: {
                let saved = isSavedByID(entry.canonicalEntryID)
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? Color.yellow : Color.secondary)
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSavedByID(entry.canonicalEntryID) ? "Unsave" : "Save")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDetailWord = wordForHistory(entry)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                historyStore.remove(id: entry.canonicalEntryID)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = entry.surface
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                selectedDetailWord = wordForHistory(entry)
            } label: {
                Label("Look Up", systemImage: "magnifyingglass")
            }

            Button {
                selectedDetailWord = wordForHistory(entry)
            } label: {
                Label("Open Details", systemImage: "info.circle")
            }

            Divider()

            let saved = isSavedByID(entry.canonicalEntryID)
            Button {
                toggleSaveHistory(entry)
            } label: {
                Label(saved ? "Unsave" : "Save", systemImage: saved ? "star.slash" : "star")
            }

            Button(role: .destructive) {
                historyStore.remove(id: entry.canonicalEntryID)
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }
}
