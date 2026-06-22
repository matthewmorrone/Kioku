import SwiftUI

// The Words screen's custom search bar: the overflow ("more actions") menu, the
// rounded search field, and the context-aware trailing filter control. Extracted
// from WordsView.body so the primary file stays under the line-count invariant.
extension WordsView {
    // Custom search field. Replaces `.searchable` so we own the chrome end-to-end and
    // don't get the iOS auto-injected Cancel button sitting beside the field.
    var customSearchBar: some View {
        HStack(spacing: 8) {
            // Overflow menu to the left of the search bar — houses actions that aren't
            // primary navigation (Edit mode, CSV import) so they don't crowd the bar
            // itself. ellipsis.circle is the system idiom for "more actions here".
            Menu {
                Button {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode == .inactive { selectedWordIDs.removeAll() }
                } label: {
                    Label(editMode == .active ? "Done Editing" : "Edit",
                          systemImage: editMode == .active ? "checkmark.circle" : "pencil")
                }
                Button {
                    isCSVImportPresented = true
                } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
                Button {
                    isSubtitleImportPresented = true
                } label: {
                    Label("Import Subtitles", systemImage: "captions.bubble")
                }
                Button {
                    isSubtitleSearchPresented = true
                } label: {
                    Label("Search Subtitles Online", systemImage: "magnifyingglass.circle")
                }

                // Kanji-discovery entry points. These four destination views + their
                // presentation flags survived the Words rebuild but were orphaned when the
                // toolbar that triggered them was deleted (nothing set the flags to `true`).
                // Re-homed here in the overflow menu. GUARD AGAINST RECURRENCE: if this menu is
                // ever restructured, grep for `isBrowseFrequencyPresented = true` (and the other
                // three flags) to confirm each trigger still exists before assuming it's wired.
                Divider()
                Button {
                    isBrowseFrequencyPresented = true
                } label: {
                    Label("Browse by Frequency", systemImage: "chart.bar.fill")
                }
                Button {
                    isBrowseProficiencyPresented = true
                } label: {
                    Label("Browse by Proficiency Level", systemImage: "graduationcap.fill")
                }
                // Folded into the main search: example sentences now surface inline beneath
                // entry results for phrase/sparse queries (WordsView.shouldShowSentenceResults).
                // Uncomment to restore the standalone corpus-search sheet.
                // Button {
                //     isSentenceSearchPresented = true
                // } label: {
                //     Label("Search Example Sentences", systemImage: "text.bubble")
                // }
                Button {
                    isRadicalInputPresented = true
                } label: {
                    Label("Find Kanji by Radical", systemImage: "square.grid.3x3")
                }
                Button {
                    isHandwritingPresented = true
                } label: {
                    Label("Handwriting Input", systemImage: "pencil.and.scribble")
                }

                // One selection menu for every tab. Because every word row selects into the
                // same selectedWordIDs set, Select All and Manage Lists are identical code on
                // Saved and History. Only the destructive verb differs — "Remove" means unsave
                // on Saved and delete-from-log on History — so just that one action is
                // contextual; everything else is genuinely shared.
                if editMode == .active {
                    Divider()
                    let selectable = selectableWordIDs
                    Button {
                        if selectedWordIDs.count == selectable.count {
                            selectedWordIDs.removeAll()
                        } else {
                            selectedWordIDs = Set(selectable)
                        }
                    } label: {
                        if selectedWordIDs.count == selectable.count && selectable.isEmpty == false {
                            Label("Deselect All", systemImage: "minus.circle")
                        } else {
                            Label("Select All", systemImage: "circle.dashed.inset.filled")
                        }
                    }
                    .disabled(selectable.isEmpty)

                    if selectedWordIDs.isEmpty == false {
                        Button {
                            isBatchListSheetPresented = true
                        } label: {
                            Label("Manage Lists…", systemImage: "text.badge.plus")
                        }
                        Button(role: .destructive) {
                            if activeTab == .history {
                                historyStore.remove(canonicalEntryIDs: selectedWordIDs)
                                selectedWordIDs.removeAll()
                                editMode = .inactive
                            } else {
                                isBatchRemoveConfirmPresented = true
                            }
                        } label: {
                            Label(activeTab == .history
                                  ? "Remove from History (\(selectedWordIDs.count))"
                                  : "Remove from Saved (\(selectedWordIDs.count))",
                                  systemImage: "trash")
                        }
                    }
                }
            } label: {
                Image(systemName: editMode == .active ? "checkmark.circle.fill" : "ellipsis.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(editMode == .active ? Color.accentColor : Color.secondary)
            }
            .accessibilityLabel("More actions")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Japanese or English", text: $searchText)
                    .focused($isSearchFieldFocused)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        // Explicit Return/Search records the phrase as a .query history
                        // entry. HistoryStore.record(query:) handles dedup + bump-to-top.
                        historyStore.record(query: searchText)
                    }
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())

            // Trailing filter control. Context-aware: while a dictionary query is active it
            // exposes the live search sort/filter menu (note/list scopes don't apply to
            // dictionary results); otherwise it's the note/list filter sheet for the
            // saved/history lists. One slot, two meanings — both use the funnel idiom and
            // flip to the filled variant when their respective filters are active.
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                dictionarySearchFilterMenu
            } else {
                Button {
                    isFilterSheetPresented = true
                } label: {
                    Image(systemName: isFilterActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isFilterActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter by Note or List")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
