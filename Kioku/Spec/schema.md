# Kioku Data Schema

This document defines the authoritative data model for Kioku.
It does not describe legacy storage.
It defines the structures the new system must persist.

All persisted state must be serializable to a full-state backup envelope.

---

## 1. Notes

A Note consists of:

- id: UUID
- title: String?
- text: String
- createdAt: Date

Notes do NOT store:
- Rendering artifacts
- Karaoke state
- Hard cuts

---

## 2. Span Model

Spans are authoritative once persisted.

Spans are stored per note:

- noteID: UUID
- spans: [[Int, Int]]

Each span is a half-open range:

    [start, end)

Coordinate system:

- UTF-16 code unit offsets

Span requirements:

- Must cover full note text
- No gaps
- No overlaps
- Strictly ascending order
- end > start

Invalid spans must never be persisted.

---

## 3. Reading Overrides

ReadingOverride:

- id: UUID
- noteID: UUID
- start: Int
- end: Int
- userKana: String?
- createdAt: Date

Constraints:

- Range must exactly match an existing span.
- Overrides never alter span definitions.
- Overrides never alter note text.

---

## 4. Saved Words

Word:

- id: UUID
- canonical_entry_id: Int
- surface: String
- reading: String?
- meaning: String?
- personalNote: String?
- sourceNoteIDs: [UUID]
- listIDs: [UUID]
- createdAt: Date

Identity:

- canonical_entry_id is authoritative identity.
- Duplicate insertion under same canonical_entry_id must merge.

Stats and history must reference canonical_entry_id.

---

## 5. Word Lists

WordList:

- id: UUID
- name: String
- createdAt: Date

---

## 6. Review Metrics

ReviewStats:

- canonical_entry_id: Int
- correctCount: Int
- incorrectCount: Int
- lastReviewedAt: Date?

Review stats are independent of surface form.

---

## 7. History

HistoryEntry:

- canonical_entry_id: Int
- lastViewedAt: Date

History is bounded recency.

---

## 8. Preferences

Preferences include:

- Typography settings
- Ruby spacing settings
- Padding toggle
- Theme
- Study configuration
- Notification schedule

Preferences are included in backup envelope.

---

## 9. Backup Envelope

Backup payload must include:

- notes
- spans
- readingOverrides
- words
- wordLists
- reviewStats
- history
- preferences
- version
- exportedAt

Restore must:

- Validate span invariants
- Reject corrupt data
- Replace state atomically

Partial backup is not permitted.

---

## 10. Canonical Dictionary Dataset (Read-Only)

Bundled SQLite dataset provides:

Core tables:

- entries
- kanji_forms
- kana_forms
- senses
- glosses

Optional tables:

- example_sentences
- pitch_accents
- embeddings
- kanji_metadata

Dictionary dataset is read-only.
User data is never written into dictionary tables.

---

## 11. Explicitly Excluded Concepts

The following do not exist in Kioku:

- Hard cuts
- Boundary-only segmentation arrays
- Karaoke alignment state
- start+length span representation
- Surface-based word identity
- Rendering artifact persistence