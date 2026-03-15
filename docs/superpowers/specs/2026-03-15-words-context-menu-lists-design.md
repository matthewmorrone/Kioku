# Words Tab: Context Menu, Word Lists & Filtering

**Date:** 2026-03-15

## Context

The Words tab currently shows saved vocabulary as a flat list with only swipe-to-delete for management. List membership is tracked implicitly via `sourceNoteIDs` on `SavedWord` (which Notes the word was saved from), but there's no dedicated word-list concept or any direct management UI. This feature introduces:

1. A first-class `WordList` model living under the Words tab's ownership
2. Proper `ObservableObject` stores for both saved words and word lists
3. A context menu on every word row (remove, copy, look up, open details, manage list membership)
4. A filter popover (multi-select by list) with inline list CRUD
5. Batch edit/remove controls on the words list

## Data Layer

### `WordList`
New model in `Kioku/Words/WordList.swift`:
```swift
struct WordList: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
}
```

### `SavedWord` — new field
Add `wordListIDs: [UUID]` to `SavedWord`. Existing `sourceNoteIDs` stays as provenance data (which Note a word was saved from) but is no longer used for list-membership UI.

Migration: `SavedWord`'s custom `init(from:)` decoder defaults `wordListIDs` to `[]` when the key is absent (same pattern as the existing `sourceNoteIDs` legacy path). `SavedWordStorageMigrator.normalizedEntries(_:)` must be updated to propagate `wordListIDs` from the input entries when constructing merged outputs — it must not drop the field by constructing new `SavedWord` values via the plain 3-arg initializer.

### `WordListsStore`
New `@MainActor final class` `ObservableObject` at `Kioku/Words/WordListsStore.swift`. Persists to `kioku.wordlists.v1`. Exposes:
- `lists: [WordList]` (published)
- `create(name:)`, `rename(id:name:)`, `delete(id:)`

`WordListsStore` has no reference to `WordsStore`. The cascade on list deletion (stripping the deleted list ID from all saved words' `wordListIDs`) is the caller's responsibility — `WordListFilterView` calls `wordListsStore.delete(id:)` then `wordsStore.removeListMembership(listID:)` in sequence. This keeps store ownership flat.

### `WordsStore`
New `@MainActor final class` `ObservableObject` at `Kioku/Words/WordsStore.swift`. Persists to `kioku.words.v1` (same key as the current direct `UserDefaults` path). Exposes:
- `words: [SavedWord]` (published)
- `add(_:)`, `remove(id:)`, `toggleListMembership(wordID:listID:)`, `removeListMembership(listID:)`

**Cut-over:** `WordsView`'s direct `UserDefaults` access (`loadSavedWordEntriesFromStorage`, `persistSavedWordEntriesToStorage`, `refreshSavedWords`, `savedWordsStorageKey`) is removed entirely and atomically when `WordsStore` is introduced. There is no transition period where both paths coexist.

Both stores injected as `@EnvironmentObject` at app level in `ContentView`, matching the `NotesStore` pattern.

## Views

### `WordRowView` (new — `Kioku/Words/WordRowView.swift`)
Owns the individual row UI. Receives the word, all lists, and action callbacks from `WordsView`. Contains:
- `.swipeActions` trailing edge: Remove (destructive, full swipe, no additional confirmation — matches existing behavior)
- `.contextMenu`:
  - **Copy** — copies `word.surface` to `UIPasteboard`
  - **Look Up** / **Open Details** — both trigger the same `onOpenDetails` callback, which presents `WordDetailView` as a sheet (same action as the existing row tap). Two entries for discoverability.
  - **Lists** submenu — one toggle per `WordList`, checkmark when `wordListIDs` contains the list ID, triggers `onToggleList` callback
  - **Remove** (destructive) — triggers `onRemove` callback; `WordsView` presents a `confirmationDialog` before deleting

### `WordListFilterView` (new — `Kioku/Words/WordListFilterView.swift`)
Popover opened from a top-right toolbar filter button in `WordsView`. Contains:
- "All" option (clears filter selection)
- Each `WordList` with a checkmark toggle (multi-select — words in any selected list are shown)
- `+` button to create a new list (inline name entry)
- Per-list swipe or context to rename / delete

### `WordsView` (modified — `Kioku/Words/WordsView.swift`)
Simplified coordinator. Uses `WordsStore` and `WordListsStore` via `@EnvironmentObject`. Responsibilities:
- Renders `WordRowView` per word (filtered by active list selection)
- Toolbar: filter button (top right), edit/select button
- `activeFilterListIDs: Set<UUID>` held in `@State` — ephemeral, not persisted, resets when the view is dismissed
- Batch mode: entering edit mode shows row checkboxes; toolbar shows "Remove" and "Manage Lists" actions for selected words
  - Batch **Remove**: `confirmationDialog` then removes all selected words
  - Batch **Manage Lists**: presents a sheet with each `WordList` and a tri-state checkbox (all selected words are members / some are / none are); confirming applies the delta
- Passes action callbacks down to `WordRowView`; handles cascade on list delete (calls both stores)

### `WordDetailView` (modified — `Kioku/Words/WordDetailView.swift`)
Update initializer: replace `membershipTitles: [String]` with `word: SavedWord` + `lists: [WordList]`, so it can display `wordListIDs`-based membership rather than the old `sourceNoteIDs` titles.

## File Summary

| New files | Modified files |
|---|---|
| `Kioku/Words/WordList.swift` | `Kioku/Words/SavedWord.swift` |
| `Kioku/Words/WordsStore.swift` | `Kioku/Words/SavedWordStorageMigrator.swift` |
| `Kioku/Words/WordListsStore.swift` | `Kioku/Words/WordsView.swift` |
| `Kioku/Words/WordRowView.swift` | `Kioku/Words/WordDetailView.swift` |
| `Kioku/Words/WordListFilterView.swift` | `Kioku/ContentView.swift` |

> **Note:** All 5 new Swift files must be manually added to the Xcode target in `Kioku.xcodeproj/project.pbxproj` (via Xcode's Add Files, or by editing the pbxproj directly).

## Verification

1. **Context menu** — long-press a word row; all 5 items appear. Lists submenu shows all word lists with correct checkmarks. Toggling adds/removes membership and persists across app restart.
2. **Swipe to delete** — still works alongside context menu Remove.
3. **Filter** — tap filter button; selecting one or more lists filters the visible words. "All" clears the filter.
4. **List CRUD** — create, rename, delete a word list from the filter popover. Deleting a list removes it from all words' `wordListIDs`.
5. **Batch edit** — enter edit mode, select multiple words, batch remove and batch list management work correctly.
6. **Migration** — existing saved words (no `wordListIDs`) decode correctly with `wordListIDs = []`.
