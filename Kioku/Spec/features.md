# Kioku Product Features

This document defines all user-visible capabilities of Kioku.
It describes what the product must do.
It does not describe implementation.

---

## 1. Top-Level Navigation

Kioku exposes five primary areas:

- Paste
- Notes
- Words
- Study
- Settings

---

## 2. Paste

### 2.1 Note Editing

Users can:

- Create a new note
- Edit note title
- Edit note body text
- Persist note changes automatically
- Delete notes
- Duplicate notes

Editing text recomputes segmentation automatically.

---

### 2.2 Furigana Rendering

Users can:

- Toggle furigana visibility
- Adjust ruby typography settings
- Toggle headword padding
- Toggle wrapping
- Toggle alternate token colors
- Highlight unknown tokens

Rendering guarantees:

- Ruby and headword wrap atomically
- Tokens never visually split across lines
- No overflow past right inset
- Alignment to left inset preserved

---

### 2.3 Token Interactions

Users can:

- Tap a token to view dictionary details
- Split a token into smaller spans
- Merge adjacent spans
- Reset a span to automatic segmentation
- Apply a custom reading override
- Replace reading with dictionary-provided reading

Span operations must always preserve:

- Full text coverage
- No gaps
- No overlaps
- Contiguity

---

### 2.4 Word Extraction

Users can:

- View tokens extracted from a note
- Hide duplicates
- Filter common particles
- Jump to token location in note
- Save one or multiple words

Saved words link to canonical dictionary entries.

---

### 2.5 Speech

Users can:

- Play note via text-to-speech
- Pause playback
- Adjust rate and voice
- See spoken-range indicator

Speech does not modify segmentation.

---

## 3. Notes

Users can:

- View list of notes
- Open note for editing
- Rename note
- Reorder notes
- Delete note
- Duplicate note

Deleting a note does not delete saved words.

---

## 4. Words

### 4.1 Dictionary Search

Users can:

- Search Japanese
- Search English
- Filter and sort results
- View detailed dictionary entry

Optional panels appear only when data exists:

- Example sentences
- Pitch accent
- Kanji metadata

---

### 4.2 Word Detail

Users can:

- View headword, reading, meaning
- View example sentences
- Speak headword
- Add/remove from lists
- Add personal note

---

### 4.3 Saved Words

Users can:

- View saved words
- View recently viewed words
- Add/remove words
- Assign to lists
- Bulk edit selections

Saved words are deduplicated by canonical entry identity.

---

### 4.4 Lists

Users can:

- Create lists
- Rename lists
- Delete lists
- Add/remove words to/from lists
- Filter by list

---

### 4.5 Import

Users can:

- Import CSV
- Preview parsed rows
- Map columns
- Enrich via dictionary lookup
- Import into list

---

## 5. Study

### 5.1 Flashcards

Users can:

- Study all words
- Study recent words
- Study incorrect words
- Study words from a specific note
- Toggle direction (JP→EN, EN→JP)
- Shuffle cards
- Mark Again or Know

Session metrics update review statistics.

---

### 5.2 Cloze

Users can:

- Select source note
- Choose sequential or random order
- Configure blanks per sentence
- Exclude duplicates
- Reveal answers
- Advance to next prompt

---

## 6. Settings

Users can:

### Appearance
- Choose theme
- Adjust typography
- Adjust ruby spacing
- Adjust line spacing
- Toggle padding

### Data
- Export full backup
- Import full backup

### Notifications
- Enable word-of-the-day
- Set notification time
- Test notification

### Misc
- Clipboard behavior
- Diagnostics toggles

---

## 7. Data-Dependent Enhancements

When data is present, Kioku may show:

- Example panels
- Pitch panels
- Embedding-based refinements
- Kanji breakdowns

If data is absent, the UI degrades gracefully.

---

## 8. Explicitly Removed Features

Kioku does not include:

- Karaoke alignment
- Hard-cut token boundaries
- Surface-based word identity
- Cloud dependency