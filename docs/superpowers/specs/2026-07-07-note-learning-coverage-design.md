# Note Learning-Coverage Screen — Design

Date: 2026-07-07
Status: Approved design, ready for implementation planning

## Summary

A new **Coverage** screen in the Learn tab that shows, for a single note, how well its
vocabulary has been learned — organized by **JLPT level** (difficulty) and **mastery stage**
(how well *you* know each word). It doubles as a launcher: tapping any level×stage cell starts a
study session scoped to exactly those words.

Building it also consolidates the app's currently-scattered "is this word learned?" logic into a
single canonical **mastery model** on `ReviewStore`, and wires the Cloze mode into the SRS so its
answers count toward mastery like Flashcards and Multiple Choice already do.

## Goals

- A per-note progress surface that makes "full learning coverage of this note" a visible target.
- One canonical definition of mastery stage (New / Learning / Learned) shared app-wide.
- Frictionless drill-down: tap a group of words → pick a mode → study just those words.

## Non-goals (explicitly out of scope)

- Redesigning the Learn tab around notes instead of study modes.
- Per-mode mastery weighting (recall vs. recognition count equally).
- Kanji coverage, a recursive component view, or any cross-note/global overview.
- Rewriting the Flashcards / Multiple Choice session UIs. They keep working as-is; they may
  *optionally* read the new shared mastery model, but no behavioral change is required of them.

## Two axes (the core mental model)

Every word in a note is classified on two independent axes:

- **Level** — JLPT difficulty, a fixed property of the word: N5, N4, N3, N2, N1, or **No level**
  (not on any JLPT list). Source: `DictionaryStore.jlptLevel(for: entryID)` →
  `Int?` where `5 == N5` (easiest) … `1 == N1` (hardest), `nil == No level`.
- **Stage** — mastery, changes as you study: **New → Learning → Learned**. Plus a **Due** flag
  that rides alongside (see below), *not* a fourth stage.

A word occupies exactly one (level, stage) cell, e.g. "N4 · Learning." The Coverage screen is a
visualization of this grid, scoped to one note.

## The shared mastery model (global change)

Today mastery is derived ad-hoc from several orthogonal signals on `ReviewStore` (keyed by
`SavedWord.canonicalEntryID: Int64`): `stats: [Int64: ReviewWordStats]`, the
`learnedState(for:) -> LearnedState { unmarked, learned, notLearned }` tri-state, and
`isDue(id:at:)`. We consolidate this into one canonical API on `ReviewStore` that the whole app
can read.

### Stage definition

Add `enum MasteryStage { case new, learning, learned }` and
`func masteryStage(for id: Int64) -> MasteryStage`, defined as:

- **Learned** — `learnedState(for: id) == .learned`. This is unchanged from today: a word reaches
  `.learned` either by manual mark or by auto-promotion through the existing, **configurable**
  `AutoLearnPolicy` (`Kioku/Settings/LearnedSettings.swift`). **We do not introduce a new
  threshold.** The user-facing "5 correct" rule already exists as `AutoLearnRule.consecutiveCorrect`
  with a default `streak` of 5, editable in Settings.
- **Learning** — not Learned, AND (`stats[id] != nil` OR `learnedState(for: id) == .notLearned`).
  I.e. the user has engaged with the word (reviewed it at least once, or explicitly marked it
  "not learned") but it hasn't cleared the bar.
- **New** — everything else: `stats[id] == nil` and not manually marked. Never touched.

### Due overlay

`Due` is orthogonal to stage — a Learned or Learning word becomes Due when its review interval
lapses. Define **Due = the word has been reviewed before AND its due date has passed**:

`func isDueForReview(id: Int64, at: Date = .now) -> Bool` → `stats[id] != nil && dueDate <= at`.

This deliberately differs from the existing `isDue(id:at:)`, which returns `true` for
never-reviewed words too. For coverage we want New and Due to be **disjoint**: New words carry
their own call-to-action; Due means "you started this and it's waiting for a review."

### Cloze into the SRS

Cloze currently records nothing (`Kioku/Learn/Cloze/` never calls `reviewStore.record*`). Wire a
correct cloze answer to `recordCorrect` and a wrong one to `recordAgain`, mirroring
`MultipleChoiceView`. All three wired modes (Flashcards, Multiple Choice, Cloze) contribute
equally to mastery.

## The Coverage screen

### Placement

A fifth page in the Learn pager. Add `case coverage` to `LearnPage`
(`Kioku/Learn/CardsTabView.swift`) and its view to the `LearnPagerView` `HStack` (keeping the enum
and HStack in sync, as the existing four do). Order: Flashcards → Multiple Choice → Cloze →
Kana Chart → **Coverage**.

Like the other Learn pages, Coverage owns its own `NavigationStack` and opens on a **note picker**
(reuse `FlashcardNotePicker` and the `WordsFilterView.notesWithSavedWords` "notes that have saved
words" source). Picking a note pushes the breakdown.

### Layout (per selected note)

1. **Summary header** — overall for the note: "*18 of 43 words learned (42%)*" with a progress
   bar (coverage % = learned ÷ total words-in-note). If any words are Due, a "*6 due*" callout.
2. **Per-level rows**, ordered easiest → hardest: **N5, N4, N3, N2, N1, then No level.** Each row
   shows the level's "*x/y learned*" and a small stacked bar split into New / Learning / Learned.
   Each stage segment (and the Due callout) is the tappable target.

There is no existing progress-bar component to reuse — the meter/stacked-bar is new UI, modeled
loosely on the text-based results layout in `FlashcardsView.sessionCompleteState`.

### Data flow

`note.id` → filter `wordsStore.words` to `word.sourceNoteIDs.contains(note.id)` (the established
in-memory pattern; there is no dedicated store query) → for each `SavedWord`, key
`canonicalEntryID` into `dictionaryStore.jlptLevel(for:)` (level axis) and the new
`reviewStore.masteryStage(for:)` / `isDueForReview(id:)` (stage axis). Aggregate into the grid.

The note scope is the outer boundary on **every count and every tap**. The only thing that reaches
outside the note is the *definition* of a stage (a word's review history is global — it may have
been drilled via other notes); *which* words appear and are counted is always just this note's
vocabulary.

## Tap to study

Tapping a non-empty cell (e.g. "N4 · Learning — 7") pops a small mode chooser —
**Flashcards / Multiple Choice / Cloze** — then pushes that mode's session over *just those words*
(this note, that level, that stage). Specifics:

- **New / Learning / Due** taps → a session over the matching words.
- **Learned** tap → a **refresher** re-drill of the mastered words (legitimately useful).
- **Empty cells (0 words)** are not tappable.

### Scope plumbing

The existing scope enum `FlashcardScope { all, dueNow, markedWrong }` already covers **Due**
(`dueNow`). Add `case new` and `case learning` so a stage maps to a real filter, computed via the
new `masteryStage(for:)`. A scoped launch carries `(noteID, level: Int?, stage)`; because the cell
already knows its exact word set, the launch can hand the resolved words to the chosen mode rather
than re-deriving them. Reuse the existing session flows — no new session UI, only a scoped entry
point into each mode.

## Testing

- `masteryStage(for:)` — New (no stats), Learning (has stats, below bar), Learning (manually
  `.notLearned`, no stats), Learned (manual), Learned (auto-promoted via `AutoLearnPolicy`).
- `isDueForReview(id:)` — never-reviewed word is **not** Due; reviewed-and-lapsed word **is** Due;
  reviewed-not-yet-due is not.
- Per-note coverage aggregation — given `SavedWord`s with `sourceNoteIDs`, a JLPT map, and review
  stats, assert the (level × stage) grid counts, the coverage %, and the Due count.
- Cloze recording — a correct cloze answer increments `stats.correct` / advances the streak; wrong
  answer records `again`.

## Open questions

None blocking. Threshold configurability is inherited from existing Settings; no new settings
surface is introduced.

## Key files

- `Kioku/Learn/CardsTabView.swift` — add `LearnPage.coverage`, wire into pager.
- New `Kioku/Learn/Coverage/CoverageView.swift` (+ supporting views) — note picker → breakdown.
- `Kioku/Learn/Flashcards/ReviewStore.swift` — `MasteryStage`, `masteryStage(for:)`,
  `isDueForReview(id:)`.
- `Kioku/Learn/Cloze/…` — record correct/again into `ReviewStore`.
- Study scope: `FlashcardScope` (+ `new`, `learning`) and the scoped launch path shared by the
  three modes.
- Reuse: `FlashcardNotePicker`, `WordsFilterView.notesWithSavedWords`,
  `DictionaryStore.jlptLevel(for:)`, `LearnHomeScaffold`.
