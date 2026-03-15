
× SegmentListView.swift:30-33
× Lattice.swift: 182-219
× ScriptClassifier.swift:206-254
× Segmenter.swift:276-303
× ReadView+Furigana.swift:444-453
× ReadView+KunyomiHeuristics.swift:44-55
× ReadView+KunyomiHeuristics.swift:78-87

---

# 1) Top-Level Navigation

- [x] Read tab
- [x] Notes tab
- [ ] Words tab
- [ ] Study tab
- [x] Settings tab

---

## 2) Read

### 2.1 Note Editing

- [x] Create a new note
- [x] Edit note title
- [x] Edit note body text
- [x] Persist note changes automatically
- [x] Delete notes
- [x] Duplicate notes
- [x] Editing text recomputes segmentation automatically

#### Note Model Contract

A note contains:

- id: UUID
- title: String?
- text: String
- createdAt: Date

---

### 2.2 Furigana Rendering

- [x] Toggle furigana visibility
- [ ] Adjust ruby typography settings
- [ ] Toggle headword padding
- [x] Toggle wrapping
- [x] Toggle alternate segment colors
- [x] Highlight unknown segments

---

### 2.3 Segment Interactions

- [x] Tap segment → dictionary entry
- [x] Split segment
- [x] Merge segments
- [x] Reset span to automatic segmentation
- [ ] Apply custom reading override
- [ ] Replace reading with dictionary reading

#### Span Model Contract

Spans are persisted per note.

Representation:

```
[[start, end]]
```

---

### 2.4 Word Extraction

- [x] Extract segments from note
- [x] Hide duplicates
- [x] Filter particles
- [ ] Jump to segment location
- [x] Save words
- [ ] Save all words
- [ ] Canonical entry linkage

---

### 2.5 Speech

- [ ] Play note TTS
- [ ] Pause playback
- [ ] Adjust rate / voice
- [ ] Spoken-range highlighting
- [x] Speech must not mutate segmentation

---

## 3) Notes

- [x] List notes
- [x] Open note
- [x] Rename
- [x] Reorder
- [x] Delete
- [x] Duplicate

---

## 4) Words

### 4.1 Dictionary Search

- [ ] Search Japanese
- [ ] Search English
- [ ] Filter and sort
- [ ] View entry detail

Optional panels appear only when dataset exists:

- [ ] example sentences
- [ ] pitch accent
- [ ] kanji metadata

---

### 4.2 Word Detail

- [ ] View headword
- [ ] View reading
- [ ] View meaning
- [ ] Example sentences
- [ ] Speak headword
- [ ] Add/remove from lists
- [ ] Add personal note

---

### 4.3 Saved Words

- [x] View saved words
- [ ] View recently viewed words
- [x] Add/remove words
- [ ] Assign to lists
- [ ] Bulk edit selections
- [ ] Canonical identity deduplication

---

### 4.4 Lists

- [ ] Create lists
- [ ] Rename lists
- [ ] Delete lists
- [ ] Add/remove words
- [ ] Filter by list

---

### 4.5 Import

- [ ] CSV import: flexible parsing
- [ ] Preview parsed rows
- [ ] Column mapping
- [ ] Dictionary enrichment
- [ ] Import into list

---

## 5) Study

### 5.1 Flashcards

- [ ] Study all
- [ ] Study recent
- [ ] Study incorrect
- [ ] Study by note
- [ ] Toggle direction
- [ ] Shuffle cards
- [ ] Again / Know
- [ ] Session updates review statistics
- [ ] Pretty interactive animations

---

### 5.2 Cloze

- [ ] Select source note
- [ ] Sequential or random order
- [ ] Configure blanks per sentence
- [ ] Exclude duplicates
- [ ] Reveal answers
- [ ] Advance to next prompt

---

## 6) Settings

### Appearance

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

---

## 7) Backup Contract

Backup envelope must contain:

- notes
- spans
- readingOverrides
- words
- lists
- reviewStats
- history
- preferences
- version
- exportedAt

---

## 8) Optional Dataset Features

When data is present Kioku may show:

- example sentences
- pitch accent
- embedding refinements
- kanji metadata

When absent the app must degrade gracefully.

---

## 9) Recommended Build Order

1. Canonical word persistence
2. Words: search → detail → lists
3. Study: flashcards then cloze
4. Backup envelope
5. Read text-to-speech + spoken highlighting
6. Settings completion
7. Optional dictionary panels

---

## 10) Explicit Non-Goals

Kioku must never implement:

- hard cuts
- boundary-only segmentation
- surface-based word identity
- mandatory network dependency
- mandatory cloud sync
