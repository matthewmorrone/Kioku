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
                    .tag(entry.id)
            }
        }
    }

    // Renders one history entry row.
    //
    // .entry rows behave as before (tap opens the detail sheet, star saves/unsaves).
    // .query rows display the phrase, tap re-populates the search field (which kicks off
    // the parse via the existing onChange handler), and have no save star — saving a
    // free-text phrase doesn't make sense in a per-entry saved-words list.
    @ViewBuilder
    func historyRow(_ entry: HistoryEntry) -> some View {
        switch entry.kind {
        case .entry:
            entryHistoryRow(entry)
        case .query:
            queryHistoryRow(entry)
        }
    }

    // Per-entry history row — uses the shared entryRow layout when the DictionaryEntry
    // is materialized (kanji + reading + first gloss + star, full-row tap target).
    // Falls back to a text-only row while the materialization is still pending.
    @ViewBuilder
    private func entryHistoryRow(_ entry: HistoryEntry) -> some View {
        let openDetail = {
            historyStore.record(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
            selectedDetailWord = wordForHistory(entry)
        }
        if let materialized = materializedHistory[entry.canonicalEntryID] {
            entryRow(
                entry: materialized,
                gloss: materialized.senses.first?.glosses.first,
                onTap: openDetail
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    historyStore.remove(historyID: entry.id)
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
                    openDetail()
                } label: {
                    Label("Look Up", systemImage: "magnifyingglass")
                }
                Divider()
                let saved = isSavedByID(entry.canonicalEntryID)
                Button {
                    toggleSaveHistory(entry)
                } label: {
                    Label(saved ? "Unsave" : "Save", systemImage: saved ? "star.slash" : "star")
                }
                Divider()
                Button(role: .destructive) {
                    historyStore.remove(historyID: entry.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        } else {
            entryHistoryRowFallback(entry, openDetail: openDetail)
        }
    }

    // Stub row used while the unified row's DictionaryEntry is still being fetched.
    // Matches the unified row's HStack/contentShape pattern so tap behavior is consistent.
    @ViewBuilder
    private func entryHistoryRowFallback(_ entry: HistoryEntry, openDetail: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(entry.surface)
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
            let saved = isSavedByID(entry.canonicalEntryID)
            Button {
                toggleSaveHistory(entry)
            } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? Color.yellow : Color.secondary)
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { openDetail() }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                historyStore.remove(historyID: entry.id)
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
                historyStore.record(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
                selectedDetailWord = wordForHistory(entry)
            } label: {
                Label("Look Up", systemImage: "magnifyingglass")
            }

            Button {
                historyStore.record(canonicalEntryID: entry.canonicalEntryID, surface: entry.surface)
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
                historyStore.remove(historyID: entry.id)
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }

    // Free-text query history row — tap re-populates the search field; no save star.
    @ViewBuilder
    private func queryHistoryRow(_ entry: HistoryEntry) -> some View {
        // Mirrors entryHistoryRow's HStack layout: text on the leading edge, icon on
        // the trailing edge in the same slot the .entry rows use for the save star.
        HStack(spacing: 12) {
            Text(entry.surface)
                .font(.body)
                .lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 16, weight: .semibold))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            searchText = entry.surface
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                historyStore.remove(historyID: entry.id)
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
                searchText = entry.surface
            } label: {
                Label("Search Again", systemImage: "magnifyingglass")
            }
            Divider()
            Button(role: .destructive) {
                historyStore.remove(historyID: entry.id)
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }
}
