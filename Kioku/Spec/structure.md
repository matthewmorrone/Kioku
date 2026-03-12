# Kioku Architecture Specification

This document defines the canonical architecture of Kioku.
It does not describe a legacy implementation.
It defines the system that must be built.

---

## 1. High-Level Architecture

Kioku is a local-first mobile application with five top-level areas:

- Paste
- Notes
- Words
- Study
- Settings

Core architectural principles:

- Declarative UI composition
- Explicit domain-state stores
- Isolated lexical processing pipeline
- Deterministic stage-ordered segmentation and rendering
- Canonical dictionary-backed identity model
- No rendering artifacts persisted

---

## 2. Layer Map

### 2.1 App Shell Layer
Responsible for:
- App startup
- Dependency wiring
- Root navigation state
- Store injection

### 2.2 Feature UI Layer
Responsible for:
- Screen composition
- Interaction surfaces
- User feedback
- Dispatching domain mutations

Must NOT:
- Own lexical logic
- Redefine segmentation
- Mutate canonical dictionary state

### 2.3 Domain State Layer
Responsible for:
- Notes
- Persisted spans
- Reading overrides
- Saved words
- Lists
- Review metrics
- History
- Preferences

Owns:
- Mutation rules
- Idempotency
- Persistence
- Backup envelope integrity

### 2.4 Lexical Processing Layer
Responsible for:
- Canonical dictionary access
- Segmentation pipeline (Stages 10–70)
- Reading attachment
- Optional embedding refinement

Must NOT:
- Mutate note text
- Persist derived rendering state

### 2.5 Rendering Layer
Responsible for:
- Attributed layout projection
- Envelope width enforcement
- Atomic segment layout guarantees

Must NOT:
- Persist layout artifacts
- Mutate note text
- Alter span definitions

---

# 3. Canonical Segmentation and Rendering Pipeline

The pipeline executes strictly in ascending stage order.
Stage numbers are canonical architectural identities.

No stage may mutate note text.

---

## Stage 10 — Lexicon Segmentation

- Produces baseline spans from dictionary surfaces.
- Does not attach readings.
- Does not consult overrides.
- Does not mutate note text.
- Produces full coverage segmentation.

---

## Stage 20 — Structural Boundary Refinement

- Applies normalization and auxiliary-chain merges.
- Applies deinflection hard-stop merges.
- May merge spans.
- Must preserve full coverage.
- Must not mutate note text.

---

## Stage 30 — Embedding Boundary Refinement (Core)

- Executes when embedding dataset is present.
- Deterministic for fixed dataset and input.
- May refine boundaries.
- Must preserve full coverage.
- Must not mutate note text.

---

## Stage 40 — Reading Attachment

- Attaches readings using morphological and dictionary-backed logic.
- Must not alter spans.
- Must not mutate note text.

---

## Stage 50 — Semantic Regrouping

- May regroup spans.
- Must preserve deterministic ordering.
- Must preserve full coverage.
- Must not alter note text.

### Stage 50 Coverage Invariant

After Stage 50:

- Union of spans must equal the full note text range.
- No gaps permitted.
- No overlaps permitted.
- Spans must be contiguous.
- Spans must be in strictly ascending order.
- Span offsets must not be altered outside regroup logic.

---

## Stage 60 — Override Projection

- Applies user reading overrides by exact range match.
- Must not alter spans.
- Must not mutate note text.

Overrides are orthogonal to segmentation.

---

## Stage 70 — Rendering Projection

- Converts spans + readings into layout representation.
- Must not mutate note text.
- Must not alter spans.
- Must not persist derived layout state.

---

# 4. Span Model

Spans are authoritative once persisted.

Spans are explicit half-open ranges:

    [start, end)

Coordinate system:
- UTF-16 code unit offsets.

Requirements:

- Spans must cover entire note text.
- Spans must be contiguous.
- No boundary-only representation.
- No hard cuts.
- No implicit segmentation.

---

# 5. Layout Atomicity Invariants

Rendering must guarantee:

- No span may visually split across lines.
- Ruby and headword wrap atomically.
- Envelope width = max(headwordWidth, rubyWidth).
- Segment block must align to left inset guide.
- Segment block must never overflow right inset guide.
- No layout artifact may be persisted.

---

# 6. Backup Envelope

Backup must include:

- Notes
- Spans
- Reading overrides
- Saved words
- Lists
- Review metrics
- History
- Preferences

Backup is full-state snapshot.
Partial backup is not permitted.

---

# 7. Non-Goals

- No cloud-sync requirement.
- No network dependency for segmentation.
- No rendering-state persistence.
- No boundary-only segment storage.