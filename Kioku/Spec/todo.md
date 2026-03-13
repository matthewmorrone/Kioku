# Kioku Feature and Parity Checklist

This file is the consolidated tracker for product features and implementation status.

Legend:

- [x] Implemented
- [ ] Remaining

## 1) Top-Level Navigation

- [ ] Paste tab name and behavior fully aligned
- [x] Read tab exists and is functional (current app label)
- [x] Notes tab exists and is functional
- [ ] Words tab fully implemented
- [ ] Study tab fully implemented
- [x] Settings tab exists and is functional

## 2) Paste (Read)

### 2.1 Note Editing

- [x] Create a new note
- [x] Edit note title
- [x] Edit note body text
- [x] Persist note changes automatically
- [x] Delete notes
- [x] Duplicate notes
- [x] Editing text recomputes segmentation automatically

### 2.2 Furigana Rendering

- [x] Toggle furigana visibility
- [ ] Adjust ruby typography settings (full contract)
- [ ] Toggle headword padding
- [x] Toggle wrapping
- [x] Toggle alternate segment colors
- [x] Highlight unknown segments

Rendering guarantees:

- [x] Ruby and headword wrap atomically
- [x] Segments never visually split across lines
- [x] No overflow past right inset
- [x] Alignment to left inset preserved

### 2.3 Segment Interactions

- [x] Tap a segment to view dictionary details
- [x] Split a segment into smaller spans
- [x] Merge adjacent spans
- [x] Reset a span to automatic segmentation
- [ ] Apply a custom reading override
- [ ] Replace reading with dictionary-provided reading

Span operation invariants:

- [x] Full text coverage
- [x] No gaps
- [x] No overlaps
- [x] Contiguity

### 2.4 Word Extraction

- [x] View segments extracted from a note
- [x] Hide duplicates
- [x] Filter common particles
- [ ] Jump to segment location in note
- [x] Save one or multiple words
- [ ] Saved words link to canonical dictionary entries

### 2.5 Speech

- [ ] Play note via text-to-speech
- [ ] Pause playback
- [ ] Adjust rate and voice
- [ ] See spoken-range indicator
- [x] Speech/transcription flows do not modify segmentation

## 3) Notes

- [x] View list of notes
- [x] Open note for editing
- [x] Rename note
- [x] Reorder notes
- [x] Delete note
- [x] Duplicate note
- [x] Deleting a note does not delete saved words

## 4) Words

### 4.1 Dictionary Search

- [ ] Search Japanese
- [ ] Search English
- [ ] Filter and sort results
- [ ] View detailed dictionary entry

Optional panels appear only when data exists:

- [ ] Example sentences
- [ ] Pitch accent
- [ ] Kanji metadata

### 4.2 Word Detail

- [ ] View headword, reading, meaning
- [ ] View example sentences
- [ ] Speak headword
- [ ] Add/remove from lists
- [ ] Add personal note

### 4.3 Saved Words

- [x] View saved words
- [ ] View recently viewed words
- [x] Add/remove words (surface-based baseline)
- [ ] Assign to lists
- [ ] Bulk edit selections
- [ ] Deduplicate by canonical entry identity

### 4.4 Lists

- [ ] Create lists
- [ ] Rename lists
- [ ] Delete lists
- [ ] Add/remove words to/from lists
- [ ] Filter by list

### 4.5 Import

- [ ] Import CSV
- [ ] Preview parsed rows
- [ ] Map columns
- [ ] Enrich via dictionary lookup
- [ ] Import into list

## 5) Study

### 5.1 Flashcards

- [ ] Study all words
- [ ] Study recent words
- [ ] Study incorrect words
- [ ] Study words from a specific note
- [ ] Toggle direction (JP to EN, EN to JP)
- [ ] Shuffle cards
- [ ] Mark Again or Know
- [ ] Session metrics update review statistics

### 5.2 Cloze

- [ ] Select source note
- [ ] Choose sequential or random order
- [ ] Configure blanks per sentence
- [ ] Exclude duplicates
- [ ] Reveal answers
- [ ] Advance to next prompt

## 6) Settings

### Appearance

- [ ] Choose theme
- [x] Adjust typography
- [ ] Adjust ruby spacing
- [x] Adjust line spacing
- [ ] Toggle padding

### Data

- [ ] Export full backup
- [ ] Import full backup
- [x] Notes export/import baseline

### Notifications

- [ ] Enable word-of-the-day
- [ ] Set notification time
- [ ] Test notification

### Misc

- [ ] Clipboard behavior
- [ ] Diagnostics toggles

## 7) Data-Dependent Enhancements

When data is present, Kioku may show:

- [ ] Example panels
- [ ] Pitch panels
- [ ] Embedding-based refinements surfaced in UI
- [ ] Kanji breakdowns

- [x] Graceful degradation when optional data is absent

## 8) Cross-Cutting Data Contracts

- [ ] Canonical saved word identity keyed by canonical_entry_id
- [ ] Review stats keyed by canonical_entry_id
- [ ] History keyed by canonical_entry_id
- [ ] Word/list persistence aligned with schema contract
- [ ] Reading override model persisted and restored per range contract
- [ ] Full-state backup/import envelope contract implemented

## 9) Recommended Build Order

- [ ] Build canonical word domain model and persistence first
- [ ] Expand Words: search to detail to lists to bulk flows
- [ ] Implement Study: flashcards first, then cloze
- [ ] Upgrade backup/import to full-state envelope and validation
- [ ] Add Read text-to-speech controls and spoken-range highlighting
- [ ] Complete Settings: theme, notifications, diagnostics, clipboard
- [ ] Add optional dictionary detail panels: examples, pitch, kanji metadata

## 10) Implementation Guardrails

Use these guardrails while completing remaining items.

- [ ] Keep span logic in UTF-16 half-open ranges [start, end).
- [ ] Validate all span mutations for full coverage, no gaps, no overlaps.
- [ ] Keep reading overrides orthogonal to spans and note text.
- [ ] Never persist rendering/layout artifacts.
- [ ] Add tests for every major feature or contract change.
- [ ] Preserve deterministic behavior for fixed input/datasets.

## 11) Architecture Conformance

- [ ] App shell owns startup, dependency wiring, root navigation state, and store injection.
- [ ] Feature UI dispatches domain mutations and does not own lexical logic.
- [ ] Feature UI does not redefine segmentation or mutate canonical dictionary state.
- [ ] Domain state layer owns notes, persisted spans, overrides, saved words, lists, review metrics, history, and preferences.
- [ ] Domain state layer owns mutation rules, idempotency, persistence, and backup envelope integrity.
- [ ] Lexical layer handles dictionary access, segmentation, reading attachment, and optional embedding refinement.
- [ ] Lexical layer never mutates note text and never persists derived rendering state.
- [ ] Rendering layer enforces layout projection and atomicity.
- [ ] Rendering layer never mutates note text or spans and never persists layout artifacts.
- [ ] Backup remains full-state snapshot only; partial backup/restore is not allowed.
- [ ] Non-goals remain enforced: no cloud-sync requirement, no network dependency for segmentation, no boundary-only segment storage.
