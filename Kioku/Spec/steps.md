# Kioku Build Execution Prompts

Submit ONE step at a time.
Do NOT combine steps.
Do NOT expand scope.
Do NOT allow architectural drift.
Each step must add tests that fail before and pass after.

---

# STEP 1 — Span Model + Invariants Enforcement

```
Implement Step 1 from spec/steps.md ONLY.

Scope:
- Allowed edits: Model layer only (Span type, SpanValidator, associated tests).
- Create files if needed inside a Model or Core folder.
- Forbidden: UI (SwiftUI views), persistence, dictionary access, pipeline stages, rendering logic, refactors outside this step.

Requirements:
- Create a Span type using explicit half-open ranges: [start, end).
- Use UTF-16 code unit offsets.
- Implement SpanValidator enforcing:
  - Full text coverage
  - No gaps
  - No overlaps
  - Strict ascending order
  - end > start
- Add XCTest coverage for:
  - Valid contiguous spans
  - Gapped spans (must fail)
  - Overlapping spans (must fail)
  - Unsorted spans (must fail)
  - Zero-length spans (must fail)
- Tests must fail before changes and pass after.

Output:
- Apply changes in place.
- No commentary.
- No extra features.
```

---

# STEP 2 — Stage 10–20 Segmentation Skeleton

```
Implement Step 2 from spec/steps.md ONLY.

Scope:
- Allowed edits: Pipeline layer only.
- Implement Stage 10 and Stage 20.
- Forbidden: UI, reading attachment, overrides, embeddings, persistence changes.

Requirements:
- Stage 10: Produce baseline spans from text input.
- Ensure full coverage.
- Stage 20: Allow merges (aux chains, deinflection groups).
- Preserve coverage invariant.
- Do not mutate note text.
- After each stage, run SpanValidator.
- Add deterministic tests for fixed input.

Output:
- Apply changes in place.
- No commentary.
- No architectural refactors.
```

---

# STEP 3 — Stage 40 Reading Attachment

```
Implement Step 3 from spec/steps.md ONLY.

Scope:
- Allowed edits: Reading attachment layer.
- Forbidden: Span boundary logic, UI, overrides, embeddings.

Requirements:
- Attach readings using dictionary-backed lookup.
- Must not modify spans.
- Validate spans unchanged before/after reading attachment.
- Add tests ensuring:
  - Span equality preserved
  - Reading values correct

Output:
- Apply changes in place.
- No commentary.
- No boundary changes.
```

---

# STEP 4 — Rendering Atomic Layout Enforcement

```
Implement Step 4 from spec/steps.md ONLY.

Scope:
- Allowed edits: Rendering layer only.
- Forbidden: Persistence, segmentation, overrides.

Requirements:
- Implement envelope width rule:
  envelopeWidth = max(headwordWidth, rubyWidth)
- Ensure:
  - Ruby and headword wrap atomically
  - No token splits across lines
  - No right inset overflow
  - Left inset alignment preserved
- Rendering must not persist layout artifacts.
- Add layout assertions or tests where possible.

Output:
- Apply changes in place.
- No commentary.
```

---

# STEP 5 — Override Shifting Logic

```
Implement Step 5 from spec/steps.md ONLY.

Scope:
- Allowed edits: Override handling layer only.
- Forbidden: Span boundary modification, UI, embeddings.

Requirements:
- Store overrides as [start, end) ranges.
- On insertion before override: shift start and end by delta.
- On deletion overlapping override: invalidate override.
- Overrides must never alter spans.
- Add tests for:
  - Insertion before override
  - Deletion inside override
  - Boundary overlap
  - Edit after override (no shift)

Output:
- Apply changes in place.
- No commentary.
```

---

# STEP 6 — Embedding Refinement (Stage 30)

```
Implement Step 6 from spec/steps.md ONLY.

Scope:
- Allowed edits: Stage 30 only.
- Forbidden: UI, persistence refactors.

Requirements:
- Implement embedding-based boundary refinement.
- Execute only if dataset present.
- Deterministic for fixed dataset.
- Preserve full coverage invariant.
- Do not mutate note text.
- Validate spans after refinement.

Output:
- Apply changes in place.
- No commentary.
```

---

# STEP 7 — Words + Canonical Identity

```
Implement Step 7 from spec/steps.md ONLY.

Scope:
- Allowed edits: Word persistence layer.
- Forbidden: Span logic, rendering.

Requirements:
- Store saved words by canonical_entry_id.
- Deduplicate on canonical_entry_id.
- Maintain review stats keyed by canonical_entry_id.
- Deleting a word must not affect notes.
- Add tests for duplicate saves and stat persistence.

Output:
- Apply changes in place.
- No commentary.
```

---

# STEP 8 — Study Layer

```
Implement Step 8 from spec/steps.md ONLY.

Scope:
- Allowed edits: Study logic layer only.
- Forbidden: Segmentation refactors, persistence schema changes.

Requirements:
- Implement flashcard session logic.
- Track correctness using canonical_entry_id.
- Update review stats correctly.
- Implement cloze using spans from notes.
- Study logic must not modify segmentation.

Output:
- Apply changes in place.
- No commentary.
```

---

Build in this order. Do not combine steps. Enforce invariants first.
