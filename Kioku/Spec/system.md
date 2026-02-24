# Kioku System Contract

This document defines runtime guarantees, invariants, and behavioral contracts.
It is authoritative for execution semantics.
It does not describe legacy behavior.

---

## 1. Execution Model

The canonical segmentation and rendering contract is Stages 10–70 as defined in structure.md.

Pipeline rules:

- Stages execute strictly in ascending order.
- Conditional stages may be skipped.
- Stage order may never be rearranged.
- No stage may mutate note text.
- No stage may persist derived layout artifacts.

For fixed:
- App build
- Dictionary dataset
- Embedding dataset
- Input text
- Persisted spans
- Persisted overrides

Pipeline output must be deterministic.

---

## 2. Note and Span Authority

A note consists of:

- Plain text
- Explicit persisted spans

Spans are authoritative once persisted.

Editing note text invalidates previous segmentation and forces full recomputation.

Span requirements:

- Half-open ranges: [start, end)
- UTF-16 coordinate system
- Full text coverage
- No gaps
- No overlaps
- Strictly ascending order

Invalid span states must never be persisted.

---

## 3. Override Model

Reading overrides are:

- Range-scoped per note
- Exact range match only
- Orthogonal to segmentation

Overrides:

- Never alter spans
- Never alter note text
- May shift if text is inserted before range
- Must invalidate if deletion overlaps range

Overrides are projection-only and applied at Stage 60.

Boundary-only overrides are not permitted.

---

## 4. Saved Word Identity

Saved words are linked by:

    canonical_entry_id

Surface form and reading are display properties.

Insertion rules:

- Idempotent under canonical_entry_id
- Duplicate saves enrich metadata, not duplicate rows

Stats are keyed by canonical_entry_id.

Deleting a saved word must not corrupt note state.

---

## 5. History and Review Metrics

History:

- Keyed by canonical_entry_id
- Bounded recency list
- Independent of note state

Review metrics:

- Keyed by canonical_entry_id
- Persisted across sessions
- Included in backup envelope

Stats are not tied to surface strings.

---

## 6. Backup and Restore

Backup envelope includes:

- Notes
- Spans
- Overrides
- Saved words
- Lists
- Review metrics
- History
- Preferences

Restore must:

- Replace in-memory state atomically
- Validate span contiguity before commit
- Reject corrupt backup data explicitly

Partial restores are not permitted.

---

## 7. Layout Enforcement Contract

Rendering must enforce:

- Atomic token wrapping
- Ruby and headword wrap together
- Envelope width = max(headwordWidth, rubyWidth)
- No right inset overflow
- Left inset alignment preserved

Layout violations must never be silently persisted.

---

## 8. Concurrency Guarantees

- Lexical processing occurs off the UI thread.
- UI publication occurs on UI-safe execution context.
- Stale pipeline results must not overwrite newer note edits.
- Long-running stages must be cancellation-aware.

---

## 9. Failure Boundaries

- Dictionary lookup failure must not block editing.
- Missing optional datasets must degrade gracefully.
- Span invariant violations must fail loudly.
- Backup import errors must surface explicit error state.

---

## 10. Non-Goals

- No hard cuts.
- No boundary-only segmentation.
- No karaoke subsystem.
- No layout-state persistence.
- No surface-based identity model.