# JLPT Proficiency Levels (N5–N1) — Design

**Date:** 2026-06-21
**Status:** Approved (design); pending implementation plan

## Goal

Expose JLPT proficiency levels (N5 = easiest … N1 = hardest) throughout Kioku so the
user can browse, filter, and study vocabulary by level. Three user-facing surfaces,
all backed by one shared data foundation:

1. **Browse by Proficiency Level** — a discovery view alongside "Browse by Frequency".
2. **Flashcards / Multiple Choice** — a JLPT level filter on each study-mode home.
3. **Global saved-words filter** — a JLPT scope in the Words "Show" filter.

## Background / constraints

- JLPT is fundamentally a *vocabulary* list. The dataset today has JLPT only for
  individual **kanji characters** (`kanji_characters.jlpt_level`, the old 4-level
  scale 1–4) — there is **no word-level JLPT data**, and `DictionaryEntry` has no
  JLPT field.
- The JLPT organization stopped publishing official vocab lists after 2010. Every
  available word→level dataset is therefore an **unofficial community estimate**
  (the well-known ones derive from Jonathan Waller's / tanos.co.uk lists). UI copy
  must reflect this — label as "estimated", never "official".
- Decision (user): source word-level JLPT by **importing a curated word list** at
  build time (not deriving from kanji, which mismatches official vocab lists and
  leaves kana-only words unlabeled).

## Data foundation (shared by all three surfaces)

### Build time — `Resources/generate_db.py`
- Import a permissively-licensed community JLPT vocab dataset mapping word
  (kanji and/or kana surface) → level. **Licensing must be verified during
  implementation** before committing the dataset; record the source + license in
  the build script.
- Match each dataset item to JMdict entries by surface: **kanji form first, kana
  form as fallback**.
- Populate a new table:
  ```sql
  CREATE TABLE entry_jlpt_level (
      entry_id INTEGER PRIMARY KEY,
      level    INTEGER NOT NULL   -- 5 = N5 (easiest) … 1 = N1 (hardest)
  );
  ```
- Conflict rule: if one entry matches dataset items at multiple levels, keep the
  **easiest** (highest N-number / largest stored integer).

### Runtime — `DictionaryStore`
- On first use, load the full `entry_jlpt_level` table into an in-memory
  `[Int64: Int]` map (`entry_id → level`). ~8k rows; cheap.
- Expose:
  - `func jlptLevel(for entryId: Int64) -> Int?`
  - `func fetchEntriesByJLPT(level: Int, limit: Int?) -> [DictionaryEntry]`
    (ordered by JPDB frequency within the level).
- Words absent from the dataset return `nil` and are excluded from level filters.

## Surface 1 — Browse by Proficiency Level

- New `Kioku/Words/BrowseProficiencyView.swift`, a near-clone of
  `BrowseFrequencyView.swift`:
  - Trailing toolbar menu selects level **N5–N1** (replacing the Top-N picker).
  - Persist selection in `@AppStorage("browseProficiency.level")`.
  - List rows reuse `DictionarySearchResultRow` with the same star / tap behavior
    (`isSaved`, `onToggleSave`, `onSelectEntry` closures passed in by `WordsView`).
  - Loads via `dictionaryStore.fetchEntriesByJLPT(level:limit:)` off the main actor.
  - `ContentUnavailableView` fallback when no level data is present in the build.
- Trigger: add a button to the `ellipsis.circle` overflow menu in
  `WordsView+SearchBar.swift`, directly below "Browse by Frequency"
  (icon `graduationcap.fill`), setting a new `isBrowseProficiencyPresented` flag.
- Presentation: add the `@State` flag + `.sheet` in `WordsView.swift`, mirroring the
  existing `isBrowseFrequencyPresented` wiring.
- **Pure discovery — no "Study these" button** (decision A). Studying a level is
  covered by Surfaces 2 and 3, which operate on saved words. This keeps the Browse
  view consistent with Browse by Frequency and avoids an ephemeral-deck path the
  study engine does not have today.

## Surface 2 — Flashcards / Multiple Choice

- New shared `FlashcardJLPTPicker` view (mirrors the existing `FlashcardNotePicker`
  in `FlashcardsView.swift`; `internal` so Multiple Choice reuses it).
  - Multi-select **N5–N1**; empty selection = no JLPT narrowing.
  - Each option shows a count suffix (words at that level in the current base),
    matching the note picker / scope-label idiom.
- Add the picker as a `Section` on both `reviewHome` screens
  (`FlashcardsView` and `MultipleChoiceView`), adjacent to the Note dropdown.
- Extend `wordsMatchingSelection()` (and the MC equivalent) to AND-combine a JLPT
  filter using `dictionaryStore.jlptLevel(for:)` with the existing scope + note
  filters. `dictionaryStore` is already a property on both views.
- New `@State private var selectedJLPTLevels: Set<Int> = []` on each view.

## Surface 3 — Global saved-words filter

- Add a **"JLPT Level"** submenu to `WordsFilterView`'s `scopeMenuContent`
  (`Kioku/Words/WordsFilterView.swift`), listing N5–N1 with the existing
  single-value scope semantics (checkmark on active; re-tap returns to History).
- Thread a new `@Binding var jlptLevel: Int?` from `WordsView` through
  `WordsFilterView`, and apply it in `WordsView`'s saved-words filtering pipeline
  (same place note/list/stat scopes are applied). Selecting a JLPT level clears the
  other single-value scopes, consistent with the current mutual-exclusion behavior.
- Update `currentScopeLabel` to render the active level (e.g. "JLPT N5").

## Testing

- **Build pipeline:** assert `entry_jlpt_level` is populated and non-empty after a
  build; spot-check a few known words (e.g. 食べる → N5, 図書館 → N5/N4) land at the
  expected level; verify the easiest-wins conflict rule on a multi-level entry.
- **DictionaryStore:** unit-test `jlptLevel(for:)` (hit, miss) and
  `fetchEntriesByJLPT(level:limit:)` ordering + limit.
- **Filtering:** test `wordsMatchingSelection()` AND-composition (scope × note ×
  JLPT), including empty-selection passthrough and words with `nil` level excluded.
- **Manual:** browse each level; confirm overflow-menu entry; confirm flashcards/MC
  dropdown filters the deck; confirm global filter scopes the saved list and label.

## Out of scope

- Reconciling the existing old-scale kanji `jlpt_level` (1–4) with the new N5–N1
  word scale. Left untouched.
- Per-sense JLPT (level is per entry, easiest-wins).
- Surfacing a JLPT badge on word detail / search rows (possible follow-up).
