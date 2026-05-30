import SwiftUI

// Toolbar content for the Words screen — browse/import entrypoints on the leading edge
// and the edit/sort/filter cluster on the trailing edge, all gated by tab + edit mode + search state.
extension WordsView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // CSV import floats to the leading side, separate from CRUD controls.
        if activeTab == .saved && editMode == .inactive && searchText.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isCSVImportPresented = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Import CSV")
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if searchText.isEmpty {
                if editMode == .active {
                    // Batch delete for whichever tab is active.
                    Button {
                        if activeTab == .saved {
                            isBatchRemoveConfirmPresented = true
                        } else {
                            isBatchRemoveHistoryConfirmPresented = true
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .disabled(activeTab == .saved ? selectedWordIDs.isEmpty : selectedHistoryIDs.isEmpty)
                    .accessibilityLabel("Delete Selected")

                    // Select all / deselect all for whichever tab is active.
                    Button {
                        if activeTab == .saved {
                            if selectedWordIDs.count == visibleWords.count {
                                selectedWordIDs.removeAll()
                            } else {
                                selectedWordIDs = Set(visibleWords.map(\.canonicalEntryID))
                            }
                        } else {
                            if selectedHistoryIDs.count == historyStore.entries.count {
                                selectedHistoryIDs.removeAll()
                            } else {
                                selectedHistoryIDs = Set(historyStore.entries.map(\.id))
                            }
                        }
                    } label: {
                        let allSelected = activeTab == .saved
                            ? selectedWordIDs.count == visibleWords.count
                            : selectedHistoryIDs.count == historyStore.entries.count
                        Image(systemName: allSelected ? "minus.circle" : "circle.dashed.inset.filled")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(
                        (activeTab == .saved
                            ? selectedWordIDs.count == visibleWords.count
                            : selectedHistoryIDs.count == historyStore.entries.count)
                        ? "Deselect All" : "Select All"
                    )
                }

                // Edit mode toggle — shown for saved always, for history only when non-empty.
                if activeTab == .saved || historyStore.entries.isEmpty == false {
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                        if editMode == .inactive {
                            selectedWordIDs.removeAll()
                            selectedHistoryIDs.removeAll()
                        }
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark.circle" : "pencil")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(editMode == .active ? "Done Editing" : "Edit")
                }

                // Sort menu — available on both tabs when not in edit mode.
                if editMode == .inactive {
                    Menu {
                        let currentSort = activeTab == .saved ? savedSort : historySort
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.newestFirst.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.newestFirst.rawValue }
                        } label: {
                            if currentSort == .newestFirst {
                                Label("Newest First", systemImage: "checkmark")
                            } else {
                                Text("Newest First")
                            }
                        }
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.oldestFirst.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.oldestFirst.rawValue }
                        } label: {
                            if currentSort == .oldestFirst {
                                Label("Oldest First", systemImage: "checkmark")
                            } else {
                                Text("Oldest First")
                            }
                        }
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.aToZ.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.aToZ.rawValue }
                        } label: {
                            if currentSort == .aToZ {
                                Label("A to Z", systemImage: "checkmark")
                            } else {
                                Text("A to Z")
                            }
                        }
                        Button {
                            if activeTab == .saved { savedSortOrder = WordsSortOrder.zToA.rawValue }
                            else { historySortOrderRaw = WordsSortOrder.zToA.rawValue }
                        } label: {
                            if currentSort == .zToA {
                                Label("Z to A", systemImage: "checkmark")
                            } else {
                                Text("Z to A")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Sort")
                }

                // Filter / list management — only meaningful for saved words.
                Button {
                    if activeTab == .saved && editMode == .active && !selectedWordIDs.isEmpty {
                        isBatchListSheetPresented = true
                    } else {
                        isFilterSheetPresented = true
                    }
                } label: {
                    Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(activeTab == .saved && editMode == .active && !selectedWordIDs.isEmpty ? "Manage Lists for Selection" : "Filter by List")
            }
        }
    }
}
