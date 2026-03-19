# Study Tab Plumbing Assessment (Kioku vs. Kyouku-style Study)

## Verdict

Kioku currently has **tab-level navigation plumbing only** for study. It does **not** yet have enough domain/state/session plumbing to emulate a full Kyouku-style Study tab (flashcards, incorrect/recent queues, direction toggles, and statistics-driven sessions).

## What already exists

- Top-level tab routing includes a Learn tab (`ContentTab.learn`) and wires `LearnView` into `ContentView`.
- `LearnView` exists as a shell view, but has no study UI sections, no state, and no workflows.
- Saved words and user-defined lists are persisted (`WordsStore`, `WordListsStore`) with canonical word identity (`SavedWord.canonicalEntryID`).

These pieces are useful prerequisites for card source material, but they are not yet a study engine.

## Missing plumbing required to emulate a Study tab

### 1) Study domain model

There is no dedicated model for:

- review stats per canonical word (correct/incorrect counters, last-reviewed timestamp)
- history of recent reviews
- session configuration (all/recent/incorrect/by-note, shuffle, direction)
- card queue and progression state

### 2) Study persistence layer

There is no `StudyStore`/`ReviewStore` equivalent that persists and publishes study metrics/history independent of view lifecycle.

### 3) Session orchestration

There is no scheduling/session logic to:

- build card sets from saved words and filters
- process grading actions (Again/Know)
- update statistics deterministically and atomically
- expose "recent" and "incorrect" subsets

### 4) Study UI composition

`LearnView` currently has no content, controls, or flows for flashcards/cloze. It is only a placeholder container.

### 5) Backup envelope integration for study data

The notes transfer payload currently exports notes metadata only. It does not include review stats/history data required for complete study-state portability.

## Practical conclusion

To emulate Kyouku's Study tab behavior, Kioku needs a dedicated study state/persistence pipeline first, then UI on top. Today, the app can route to a tab and has canonical saved words, but lacks the core review/session plumbing.

## Suggested implementation order

1. Add `ReviewStat` + `ReviewEvent` models keyed by `canonicalEntryID`.
2. Add `ReviewStore` (`ObservableObject`) for persistence + mutation APIs (`recordAgain`, `recordKnow`, queue builders).
3. Add `StudySession` domain object for queue generation and in-session progression.
4. Build `LearnView` around that state (mode selection, direction toggle, queue UI, grading).
5. Extend backup payload to include review stats/history.
