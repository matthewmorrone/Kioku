# Kioku — Claude Code Instructions

## Workflow Constraints

- Never create git worktrees. Work directly on the current branch.

## Coding Invariants

### 1. Loop Safety
Avoid `while true`. Use explicit loop conditions.
For SQLite stepping use `while stepCode == SQLITE_ROW` and explicitly handle `SQLITE_DONE`.

### 2. Error Handling
Empty `catch` blocks are not allowed. A catch must either handle the error meaningfully or rethrow it.

### 3. Type Organization
Any type (struct, enum, class, actor, protocol) that contains methods, computed properties, or other logic must live in its own file named after the type. Pure data types — structs with only stored properties, enums with only cases — may be grouped with related types in the same file. Nested type declarations are not allowed.

### 4. File Size Guardrail
- Under 800 lines preferred
- Under 1200 lines maximum

Large files must be split by responsibility.

### 5. Folder Organization
Group files by feature domain (reading, notes, dictionary, segmentation, settings). App-shell files must remain easy to locate.

### 6. Function Documentation
Every function must include a comment explaining why it exists. Complex logic must include concise inline explanation.

### 7. View Ownership Comments
Every `View` or `UIViewRepresentable` must document what screen it renders and its major layout sections.

### 8. Navigation Contract
Navigation titles must not be added unless explicitly requested.

### 9. TextKit Geometry Contract
Annotation placement must follow one coordinate pipeline:
```
TextKit rect → convert using textContainerInset → render in text-view coordinates
```
- Never cache glyph geometry
- Never compensate using `contentOffset`
- Ensure layout before querying geometry

### 10. Deinflection Contract
Deinflection must remain data-driven. Rules must live in `Resources/deinflection.json`. `Deinflector.swift` may only load rules, traverse the rule graph, and admit candidates. No hard-coded suffix rules.

---

## Data Model Invariants

**Note Persistence** — Notes must never persist rendering artifacts, layout state, or hard cuts.

**Span Invariants** — Spans must satisfy: UTF-16 coordinate system, half-open ranges `[start, end)`, full text coverage, no gaps, no overlaps, strictly ascending order, `end > start`. Editing note text invalidates segmentation and forces recomputation.

**Note Deletion Guarantee** — Deleting a note must never delete saved words. Saved words are independent of note lifecycle.

**Saved Word Identity** — Saved words are keyed by `canonical_entry_id`. Surface and reading are display properties only. Saving is idempotent under `canonical_entry_id`; duplicate saves enrich metadata. Review statistics and history must reference `canonical_entry_id`.

**Backup Restore** — Restore operations must validate span invariants, reject corrupt backups, and replace state atomically. Partial backup or partial restore is not permitted.

**History Model** — History entries are keyed by `canonical_entry_id`, bounded recency list, independent of note state.

**Review Metrics** — Must include `canonical_entry_id`, `correctCount`, `incorrectCount`, `lastReviewedAt`. Metrics persist across sessions and are included in backups.

**Determinism** — The system must remain deterministic for fixed input text, dictionary dataset, embedding dataset, persisted spans, and persisted overrides.

**Segmentation Pipeline Order** — Stages execute strictly in ascending order. Conditional stages may be skipped but ordering must not change. No stage may mutate note text or persist derived layout artifacts. Pipeline output must be deterministic for fixed inputs and datasets.

---

## Architecture Layer Boundaries

| Layer | Responsibilities |
|---|---|
| App Shell | startup, dependency wiring, root navigation |
| Feature UI | dispatch domain mutations — must not implement lexical logic |
| Domain State | notes, spans, overrides, words, lists, review stats, history, preferences |
| Lexical Processing | dictionary access, segmentation, reading attachment |
| Rendering | layout projection, ruby placement, visual invariants |

---

## Layout Enforcement

- Atomic segment wrapping: ruby and headword wrap together
- Envelope width = max(rubyWidth, headwordWidth)
- No right inset overflow
- Left inset alignment preserved
- Layout state must never be persisted

---

## Concurrency Guarantees

- Lexical processing runs off the UI thread
- UI publication occurs on the UI thread
- Stale pipeline results must not overwrite newer edits
- Long-running stages must support cancellation

---

## Failure Boundaries

- Dictionary lookup failure must not block editing
- Missing optional datasets must degrade gracefully
- Span invariant violations must fail loudly
- Backup import errors must surface explicit error states

---

## Architecture Non-Goals

The system must never introduce: hard cuts, boundary-only segmentation, layout persistence, surface-based word identity, mandatory cloud sync, mandatory network dependency.
