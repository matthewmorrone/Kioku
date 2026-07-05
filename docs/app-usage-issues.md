# App-usage issues

Running log of issues found while actually using the app, captured live during a
usage session. Each entry is written so a new session can pick it up cold — no prior
conversation required. Screens/wording refer to what's visible in the app UI.

When an entry is triaged into a real work item, move it into `docs/todo.md` (or fix it)
and check it off here.

Session started: 2026-07-03

**Promotion status:** #1, #2, #3, #4 all promoted into `docs/todo.md` on 2026-07-03
(#1 and #2 → Read View section; #3 and #4 → Audio & Alignment section).

---

## Open

### 1. Vocab tab wrongly empty — promoted to todo.md
- **Screen:** Extract-words sheet → **Vocab** tab (note: song 月色チャイのん, has many
  ordinary dictionary words).
- **Observed:** Shows `0 of 0 words selected`, body text `No dictionary-backed
  vocabulary in this text.`, footer button `Save 0 Words`.
- **Confirmed (2026-07-03):** This is defect (a) — the tab is *wrongly* empty; the text
  does contain dictionary-backed words. Not a messaging/UX nit.
- **Code path (from investigation 2026-07-03):** `recomputeExtractedVocab()`
  (`Kioku/Read/Segmentation/SegmentListView.swift:104`) feeds the read view's
  `segmentEdges` into `SubtitleVocabExtractor.extract(fromEdges:dictionaryStore:)`
  (`Kioku/Read/Audio/SubtitleVocabExtractor.swift:40`). After the recent fix (commit
  4d7790c forces `isDictionaryMatch = true`), the sole remaining gate is the dictionary
  lookup `dictionaryStore.lookupFirstEntryIDs(...)`
  (`SubtitleVocabExtractor.swift:78`) — any lemma missing from the in-memory
  `canonicalEntryIDMap` is dropped.
- **Two distinct root causes (the Lines tab discriminates them):**
  - **If Lines was ALSO empty:** `segmentEdges == []` when the sheet opened — the note's
    segmentation hadn't loaded (resources not ready / async restore in
    `ReadView+Persistence.swift:151-207` not yet run / `readResourcesReady == false` in
    `ReadView+Segmentation.swift:169`). Both tabs go blank.
  - **If Lines showed words but Vocab was empty (more likely here):** edges exist, so the
    dictionary resolution is failing. Prime suspect: `canonicalEntryIDMap` never
    populated — `populateCanonicalEntryIDMap()` swallows failures in a `try/catch` that
    only `print`s (`ContentView.swift:431`). If the map is empty, EVERY lemma fails to
    resolve → Vocab always empty while Lines still works. Silent, global failure.
- **Deciding diagnostic still needed:** did the **Lines** tab show words for this note?
  That splits "no edges" from "dictionary-map failure."
- **Secondary contributor:** conjugated song-lyric surfaces whose lemma hydration
  (`segmenter.preferredLemma`) returns a non-canonical form get dropped at
  `SubtitleVocabExtractor.swift:80` — explains *partial* emptiness, not total.

### 2. Active-word (karaoke) highlight has poor text contrast — promoted to todo.md
- **Screen:** Read view, current-word highlight. Example: line 「悲しみの嘘を忘れない」,
  highlighted word 「嘘」.
- **Observed:** The active word gets a **light translucent gray pill**, but the glyph
  keeps its semantic color (red for vocab, blue, etc.). Red-on-light-gray lands at
  ~2:1 contrast — the highlighted word and its furigana are nearly illegible. Worst on
  the red words, which are the ones you most want to read.
- **Root cause:** The highlight recolors the *background* only; the *foreground* stays
  whatever semantic color it already had, so contrast is left to chance.
- **Fix direction:** When a word is the active highlight, override its text color to a
  fixed high-contrast foreground instead of keeping red/blue. Options (all meet WCAG AA
  4.5:1, most hit AAA 7:1):
  - **A (recommended):** amber pill `#FFCC66` + near-black glyph `#1A1A1A` (~13:1).
    Ties into the existing orange playback/scrubber accent → reinforces "now playing".
  - **B:** near-opaque light pill `rgba(255,255,255,0.92)` + dark glyph `#1C1C1E`
    (~15:1). Neutral, no accent tie-in.
  - **C:** saturated dark pill (`rgba(90,140,210,0.85)` or solid `rgba(40,40,45,0.95)`)
    + white glyph `#FFFFFF` (~8–10:1). Keeps the dark-mode feel.
- **Principle:** semantic coloring and the highlight pill currently fight each other;
  the highlight should win and guarantee contrast.

### 3. Lyric line placed on the wrong side of an interlude — promoted to todo.md
- **Screen:** Read view, aligned lyric display.
- **Observed:** In this sequence the sung line 「悲しみの嘘を忘れない」 sits *above* the ♪
  interlude markers:
  ```
  涙色のシェノン
  悲しみの嘘を忘れない   ← currently here (before the interlude)
  ♪
  ♪
  その物語オーロール
  ```
- **Expected:** It belongs *below* the interlude — it resumes the section after the
  instrumental gap:
  ```
  涙色のシェノン
  ♪
  ♪
  悲しみの嘘を忘れない
  その物語オーロール
  ```
- **Category:** Timing/alignment. A sung line got bucketed *before* an instrumental
  break instead of after it — likely the Re-align pass assigns lines to the wrong side
  of a long inter-vocal gap.
- **Model note (from code investigation 2026-07-03):** ♪ interludes are *real* cues
  with genuine `startMs`/`endMs` (`SubtitleCue`, `Kioku/Read/Audio/SubtitleCue.swift`),
  not separate widgets. So a line displayed on the wrong side of the ♪ is a timing/order
  mismatch relative to the interlude cue — and would likely be caught by the diagnostic
  proposed in item 4.

### 4. No "never-highlighted segment" detection (alignment-quality diagnostic — missing) — promoted to todo.md
- **Origin:** Discussed 2026-07-03. Expectation was that the app can already tell when a
  segment is never highlighted during playback. It cannot — but the data supports it.
- **How highlighting works (confirmed in code):** active line =
  `AudioPlaybackController.resolveActiveCue(atMs:)`
  (`Kioku/Read/Audio/AudioPlaybackController.swift:369`) scans the playhead against each
  cue's half-open `[startMs, endMs)` range, taking the **first** match, with a fallback
  chain (next upcoming cue → last-ended cue → previously active).
- **A cue can be un-highlightable in two ways, both expressible today with no guard:**
  - **Zero/negative duration** (`startMs >= endMs`) — empty interval, playhead can never
    be inside it. `normalizeTiming`
    (`Kioku/Read/Audio/SubtitleEditorTimingTools.swift:51`) does *not* enforce a minimum
    positive duration, so such a cue survives import/normalization.
  - **Shadowed** — because the scan takes the *first* matching cue, a cue whose range is
    fully covered by an earlier cue is never returned as the current cue.
- **Status today:** No code detects, flags, filters, or logs never-highlighted / zero-
  duration / shadowed cues. Reachability against the playhead is never computed. The
  property is latent, not recorded.
- **Caveat:** The `nextCue`/`previousCue` fallback can make even a zero-duration/shadowed
  cue *flash* transiently, so "never the contains-playhead winner" is not identical to
  "never visibly lights up." A real diagnostic should be precise about which it means.
- **Proposed diagnostic:** simulate `resolveActiveCue` across the full timeline (or just
  check `startMs >= endMs` and coverage/overlap) and surface cues that are never the
  active winner. This would auto-catch bugs like item 3 (line on the wrong side of an
  interlude) and any mis-timed/orphan line. Candidate for promotion into `docs/todo.md`
  as an alignment-quality check.

---

## Resolved

_(none yet)_
