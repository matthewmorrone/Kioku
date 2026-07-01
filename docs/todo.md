# Todo

Single source of truth for Kioku product, infrastructure, and triage work.
Each entry is written so a new session can pick it up cold — no prior conversation
required.

Last consolidated: 2026-05-25 (merged `infra-backlog.md` and `test-failures.md` here).

---

## Regression watch

- [x] **Re-wire the four kanji-discovery entry points on the Words tab** — Done 2026-06-04.
      Confirmed the diagnosis exactly: the `.sheet(isPresented:)` modifiers, the four state
      flags (`isBrowseFrequencyPresented`/`isSentenceSearchPresented`/`isRadicalInputPresented`/
      `isHandwritingPresented`), and all four destination views were intact and compiling, but
      nothing set any flag to `true`. Added a Discover group to the `ellipsis.circle` overflow
      menu in `WordsView.customSearchBar` (below Edit/Import, behind a Divider): Browse by
      Frequency (`chart.bar.fill`), Search Example Sentences (`text.bubble`), Find Kanji by
      Radical (`square.grid.3x3`), Handwriting Input (`pencil.and.scribble`). Placement chosen
      by user (section-in-ellipsis over dedicated button / leading toolbar). Recurrence guard
      noted inline in the code comment (grep `isBrowseFrequencyPresented = true` etc. before
      assuming wired). Builds clean.

- [x] **Keep the "filter by associated note" (and list) filter** — Verified present
      2026-06-04. The anticipated reconciliation already happened: `WordsFilterView` is now a
      unified "Show" dropdown (Favorites / per-source-note / per-list scopes) and BOTH the note
      filter (`notesWithSavedWords` → `tapNote`/`selectNote`) and list filter survived. Reached
      via the funnel button in `WordsView.customSearchBar` (`isFilterSheetPresented`) and applied
      in `visibleWords` via `activeFilterNoteIDs`/`activeFilterListIDs`. Note scopes still only
      appear for notes with populated `sourceNoteIDs` (`notesWithSavedWords`). No code change
      needed — the watch is discharged.

## Bugs

- [x] Ruby persistent overhang spacing on the left edge — Resolved by design. The overhang
      compensation was intentionally removed (`f4be1b9`) in favor of standard Japanese typography
      (kanji sits flush at the inset, ruby overhangs into the margin); follow-up furigana fixes
      settled it (`1d4c397` center ruby on kanji run, `e832a83` align inset, `f94974f`). The
      orphaned `KiokuWideRubyLineInset.swift` + test can be removed in a cleanup pass.
- [x] Distribute spacing better for multikanji ruby headwords — Addressed via the ruby-spacing
      kern pass (`da402ec` "add ruby-spacing kern pass to prevent overlap") plus global kerning +
      headword padding controls (`196d190`) and the shipped `furiganaGap`/`kerning` settings.
- [x] Combining or splitting words: save button state not refreshed after merge/split
- [x] Clicking the star button doesn't always trigger bookmarking (bookmark button works) —
      Done 2026-06-04. The lookup sheet's star (`saveButton` → `sheetSaveToggle`) guarded on
      `SegmentLookupSheet.shared.currentSheetDictionaryEntry`, which is resolved *asynchronously*
      after the sheet presents (so the open animation isn't blocked by SQL). Tapping during that
      window hit a nil entry and silently no-op'd — intermittent by nature. Fix: fall back to the
      synchronous `resolvedDictionaryEntryForCurrentSelectedSegment()` when the async entry hasn't
      landed (`?? `), mirroring the sibling `sheetOpenWordDetail` closure
      (`ReadView+Segmentation.swift`). The async entry stays preferred (it's reading-disambiguated
      for homographs).
- [x] Typing freely in English in the paste area is super laggy — Done 2026-06-04. ReadView keeps
      the read-only `KiokuCoreTextRendererView` mounted behind the editable `RichTextEditor` (for
      instant edit↔view toggles), hidden via `.opacity(0)` in edit mode. But it stayed in the view
      tree, so SwiftUI called its `updateUIView` on every keystroke, and its typography fingerprint
      includes the full `text` — so each character triggered a complete off-screen CoreText
      re-typeset of the whole note. Added an `isActive` param (default true); `updateUIView`
      early-returns when inactive, and the call site passes `isActive: isEditMode == false`. The
      renderer keeps its last view-mode content and rebuilds once when editing ends. (`RichTextEditor`
      itself already guarded correctly — `lastRenderedText` is synced in `textViewDidChange` before
      `updateUIView` runs.)
- [x] **Favorited word not highlighted when favorited more than once in one note** — Resolved
      2026-06-15 by `4cfe3cb` "fix(read): glow conjugated favorites by not caching nil lemmas".
      The actual root cause was NOT the lemma-ambiguity hypothesis below: `FavoritedGlowMemo.lemmaBySurface`
      (typed `[String: String?]`) cached `nil` when the first glow pass ran before the segmenter's
      deinflection resources finished loading. Keyed by the unchanging note text, that `nil` stuck for
      the whole session, so any conjugated surface (なびかせて, 消えて…) never bridged to its saved
      lemma — base forms glowed (direct match), conjugations never did. Fix: cache only successful
      resolutions so each recompute retries until resources are ready. Pinned by
      `FavoritedGlowLemmaBridgeTests.swift` (real-segmenter lemma-bridge predicate). The
      multi-candidate `resolvedSavedKey` rework theorized below was unnecessary and was not done.
      (Original 2026-06-04 investigation notes kept for history:)
      - The 2026-06-04 trace found every scenario worked *statically* and suspected
        `preferredLemma` returning a different member of an ambiguous lemma pair (靡かす vs 靡かせる)
        than the one saved. That couldn't be confirmed by static reading — and the nil-caching race
        above turned out to be the real cause.

## Segmentation & Lookup

- [x] Halfwidth katakana normalization in lookup (ｱｲｳｴｵ → アイウエオ)
- [x] Lexicon lemma ranking respects saved-word surfaces when scoring inflection candidates (`Lexicon.swift:241-270` — `resolve()` ranks lexemes by saved surface + inflection-chain score)
- [x] Use frequency data to influence segmentation path selection — Done. The Viterbi cost
      path applies a frequency term as its primary statistical signal: `costFrequencyWeight = 3.0`
      subtracts `costFrequencyWeight * edge.frequencyScore` from each edge cost
      (`SegmenterScoring.swift:36-47, 165-174`), with surface-then-lemma frequency resolution in
      `Segmenter.swift`. (This is the reason the cost-path segmenter beats greedy.)
- [ ] Provide meaning of verbs in the form they surface in — still open (verified 2026-06-30,
      NOT stale). The lookup sheet filters senses by selected reading/kanji, but glosses come
      straight from JMdict lemma-indexed `sense.glosses`; there's no surface-form-specific gloss
      annotation. **Closely related to "Name the inflected form" below** — that one *labels* the
      conjugation ("causative + te-form"); this one *glosses the meaning* in that form. Both are
      "show inflection info in the lookup UI" and could be done together; neither is in the UI yet.
- [x] **Name the inflected form of a verb surface** — Done 2026-06-30. New
      `InflectionFormNames.describe(_:)` (`Kioku/Dictionary/Deinflection/InflectionFormNames.swift`)
      maps the deinflector's grouped-rule chain labels (camelCase group keys from
      `deinflection.json`, e.g. `teForms`→"te-form", `politeForms`→"polite") to a short
      description, dropping internal `*RecoveryForms` stem-recovery steps. The lookup header's
      lemma label (`SurfaceSheetViewController.updateLemmaChain()`) now appends the form beside the
      dictionary lemma in a smaller secondary style (e.g. "靡く · te-form") for inflected surfaces,
      falling back to lemma-only when the chain has no displayable forms. Pinned by
      `InflectionFormNamesTests.swift` (5 tests). The chain was already computed
      (`Lexicon.inflectionInfo`/`inflectionChain`) — this exposes it in the UI.

### Still-broken segmentation cases

- **ニュームーン → ニューム + ーン (katakana long-vowel run split wrong)** — the katakana
  loanword ニュームーン ("new moon") mis-segments into ニューム + ーン, with the second
  piece (ーン, a bare long-vowel mark + ン) unrecognized. The katakana long-vowel mark (ー)
  inside a loanword run is being treated as a segment boundary instead of part of the
  preceding mora. Should resolve to a single segment ニュームーン. Likely the same
  katakana long-vowel handling that the トキメク / ショーブ expansion cases exercise — audit
  how ー is normalized/expanded mid-run during longest-match. Add a pin in
  `SegmentationKnownGoodTests` once fixed.

- **の + またたく → のまたたく (fused)** — sentence `命は闇の中のまたたく光だ`
  parses to 8 segments instead of 9. The Viterbi/MeCab path fuses the possessive
  particle の with the following verb またたく into a single surface のまたたく
  (sometimes also splits as のま + たたく, with のま resolving to the 連用形 of
  飲ます "to make drink"). Hypothesis: bigram cost of の-prt + またたく-verb is
  higher than のま-verb + たたく-verb, even though the former is correct here.
  Same sentence also misreads 闇 (やみ) as くらい — the reading for 暗い, an
  unrelated entry, suggesting the homograph lookup is picking the wrong sense.
  Fix path: revisit Viterbi bigram calibration for prt→verb transitions and
  audit whether 闇's canonical kana row is being passed over for 暗い's.

### Intentionally unrecognized

- **ちゃいのん** — context-specific stylization from the song title 月色チャイのん.
  Not a generalizable lemma; no authoritative gloss exists. Decision (2026-05-25):
  leave out of the lexicon rather than fabricate a meaning. If a future song or
  context provides a real meaning, add to `extras.json` and pin in
  `SegmentationKnownGoodTests`.

## Read View

- [x] **Scroll back to the top when opening a note** — Done 2026-06-04. Root cause: the
      active CoreText renderer (`KiokuScrollingTextView`) owns its own scroll offset and was
      never wired to the `sharedScrollOffsetY = 0` reset in `ReadView+Persistence.swift` (that
      reset only drove the now-disabled `FuriganaTextRenderer` path). Added a one-shot
      `scrollToTopToken` to `KiokuCoreTextRendererView` keyed on `activeNoteID?.hashValue`;
      on a token transition `scrollToTopIfTokenChanged` resets the offset to `-inset.top`
      exactly once (a token, not a binding, so it can't fight the user's own scrolling). Runs
      before the playback auto-scroll so an active cue can still win the rare overlap.
- [x] **Split segments show dashes instead of frequency scores** — Done 2026-06-04. Root
      cause was an optional-chain emptiness trap, not a missing lookup: every frequency
      resolver did `if let data = surfaceReadingData[surface]?.frequencyByReading { return data }`.
      A surface present in `surface_readings` but carrying no jpdb/wordfreq signal has an
      *empty* `frequencyByReading`, so the early return fired with `[:]` (non-nil) and
      short-circuited the lemma fallback — `normalizedSheetFrequencyScore([:])` then returned
      nil and the split editor rendered "surface –". Bare split fragments routinely land on
      such frequency-less-but-present entries, which is why it read as split-only. Fix:
      extracted one shared `frequencyData(forSurface:)` resolver on ReadView
      (`ReadView+SheetSelection.swift`) with a `data.isEmpty == false` guard on both the direct
      and lemma lookups, and routed `pathSegmentFrequencyProvider`, `frequencyRankForCurrentSelectedSegment`,
      and the nested-compound `frequencyForSurface` through it (was three near-identical inline
      copies of the buggy pattern).
- [x] **Overscroll doesn't lift the tapped word above the lookup sheet** — Done 2026-06-04.
      The overscroll mechanism (`temporaryBottomInset` in `ReadViewSheetVisibilityScrollPlanner`)
      was already present; the bug was in the coverage estimate. `expectedCoveredHeight =
      min(max(360, vh*0.64), vh*0.5)` — the `maximumCoveredHeightRatio: 0.5` cap sat *below* the
      `estimatedRelativeCoverage: 0.64` estimate, so the cap unconditionally won and the planner
      only ever reserved 50% of the viewport. But the `.medium()` lookup sheet covers ~64% of the
      (nav/tab-bar-excluded) read viewport, so words tapped in the 50–64% band landed behind the
      sheet. Raised the cap to 0.72 so the 0.64 estimate governs while still guarding against
      degenerate over-reservation (`ReadView+SheetSelection.swift`).
- [ ] **In-place context menu on the Read tab** — offer a lightweight context menu anchored
      at the tapped word for quick actions, instead of always presenting the full lookup
      sheet. Build it first; decide replace-vs-additional (tap→menu vs long-press→menu +
      tap→sheet) after evaluating how it looks and feels.
- [ ] Quiz on next and previous words/lines
- [ ] **Unify the two LLM call paths into a single merged, context-sharing call** —
      today `Kioku/Read/LLM/LLMCorrectionService.swift` (segmentation/reading correction)
      and `Kioku/Learn/Songs/SongBreakdownService.swift` (per-line breakdown) are two
      separate round-trips with duplicated HTTP plumbing and *no shared context*: the
      segmentation pass doesn't see song-level poetic register/established imagery, and
      the breakdown pass has no access to the segmentation's authoritative readings, so
      surfaces and per-word annotations can drift out of sync. Two-phase refactor:
      1. **Extract `LLMClient`** owning provider dispatch (OpenAI/Claude/stub), HTTP,
         validation, errors. Both services currently duplicate `callOpenAI` /
         `callClaude` / `validate` (~150 LOC each). Per-call-site policy stays a
         parameter: timeouts (5min for songs vs 60s for segmentation), max_tokens (8192
         vs 4096), system-message use, stub-key (`kioku.llm.song.stubResponse` vs
         `LLMSettings.stubResponseKey` + bundled `llm_stub.txt` fallback).
      2. **Merge the song call** so one LLM round-trip returns both corrected
         segmentation *and* breakdown in a single structured-JSON response.
         Segmentation has song context (better splits for poetic compounds); breakdown
         references segments by id, so surfaces stay in sync and romaji is derived
         from the assigned readings at render time rather than re-emitted by the
         model. Use OpenAI `response_format: { type: "json_schema", strict: true }`
         and Anthropic forced-tool-use for schema enforcement.
      - **Wire format:** structured JSON (option C). Schema sketch:
        ```json
        {
          "segments": [{"id": 0, "line": 1, "surface": "朽ち", "reading": "くち"}, ...],
          "lines": [{
            "index": 1,
            "gist": "Twilight wings rest on decayed petals.",
            "words": [{"segment_ids": [0,1], "definition": "..."}, ...],
            "grammar_note": null,
            "reference": null   // or {"kind":"same_as","line":N} / {"kind":"parallel","line":N,"substitution":"X → Y"}
          }, ...]
        }
        ```
        `segments[]` is the single source of truth — no `romaji` field anywhere
        (derived from `reading` via existing kana→romaji at display). Per-word bullets
        reference segments by id, not retyped surface — editing a segment in Read view
        propagates to the bullet automatically. `words[]` is sparse — pure case
        particles (が/を/に) don't get bullets, matching today's prompt rule 5.
        `original` field omitted on purpose (reconstructable from segments filtered by
        line; one less drift surface).
      - **Render rule (option B):** drop romaji from prompt entirely; renderer derives
        it from each segment's `reading`. Existing kana→romaji converter handles this.
      - **Migration:** existing cached breakdowns are markdown — either invalidate on
        first read or keep `SongBreakdownParser` around for one transitional version and
        re-fetch lazily. Stub mode becomes JSON; ship a one-shot converter from an
        existing markdown stub to seed the new format.
      - **OPEN QUESTION (needs decision before implementation):** triggering rule when
        the user taps "Improve segmentation" in Read view on a song note. Options:
        (a) cheap path — segmentation-only call (~4k tokens), breakdown stays a
        separate later call; (b) merged path — always fire the full ~8k-token call so
        the breakdown is pre-cached. (b) is strictly cheaper if a breakdown will ever
        be requested; (a) wastes nothing for segmentation-only users. Suggested
        default: merged path if a breakdown exists or has ever been requested for the
        same lyric hash; cheap path otherwise.
      - Files touched: new `Kioku/LLM/LLMClient.swift` (or similar), `LLMCorrectionService.swift`,
        `SongBreakdownService.swift`, `SongBreakdownPrompt.swift`, `SongBreakdownParser.swift`
        (replaced by JSON decoder), `SongLine`/`SongWord` models (gain `segmentIDs` field),
        breakdown UI (`SongLineCard.swift` — render romaji from referenced segments).

## Words & Dictionary

- [x] Add personal note to saved words
- [x] CSV import: flexible parsing (`CSVImport.swift` `parseItems()` handles varied column layouts)
- [x] List conjugations in dictionary view (`WordDetailView.swift:33-34` + `ConjugationSheetView.swift`)
- [x] Variants section in WordDetail: list all kanji and kana forms of the entry, labeled, separate from the saved surface (`WordDetailView.swift:4`)
- [ ] Add manual/custom word creation and editing
- [x] Deduplicate example sentences — `Kioku/Dictionary/SentencePairDedup.swift` normalizes (trim, strip wrapping quote pair, strip trailing sentence-final punctuation) then dedupes preserving order. Wired into both `fetchSentencePairs` (replaces the prior exact-string `seenJapanese` set, now catches Tatoeba near-duplicates across priority terms) and `searchSentences` (which had no dedup at all). Pinned by 7 tests in `SentencePairDedupTests.swift`.
- [x] Custom reading popup is prefilled — `SurfaceSheetViewController.presentCustomReadingAlert()` sets `field.text = self.displayedReading()` at line 212, so the prompt opens with the current reading already in the field.
- [x] Custom reading popup should default to Japanese keyboard — Done 2026-06-30. Replaced the
      `UIAlertController` in `SurfaceSheetViewController.presentCustomReadingAlert()` with a custom
      `JapaneseReadingPromptController` (new `Kioku/Read/Lookup/JapaneseReadingPrompt.swift`) that
      hosts a `JapaneseTextField` subclass overriding `textInputMode` to prefer
      `UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("ja") == true }`
      (falls back to the system default when no Japanese keyboard is installed). The prompt
      preserves the prior flow exactly — prefilled current reading, "e.g. よむ" placeholder,
      Set / Cancel / conditional destructive Reset (gated on `activeReadingOverrideProvider`).
- [x] Make saving to the words list more responsive — shipped via `WordsStore.persistQueue` (serial utility-QoS DispatchQueue) so star-toggles return immediately and persist off-main; lemma-cache + off-main hydration on `SegmentLookupSheet` load eliminates the redundant SQL pass that was making first-tap latency visible. `WordsStore.flushPendingWritesForTesting()` provides the sync surface for tests.
- [x] Add advanced dictionary filters/sorting (JLPT, POS, frequency, commonness toggles) —
      Completed 2026-07-01 (the frequency-threshold control was the last gap). Partially done
      2026-06-04: the filter/sort *logic* was fully built but orphaned (same
      pattern as the kanji-discovery regression — `WordsView+Search.swift` even carried a "filter
      UI removed; helpers kept so a replacement can rewire later" comment, and none of
      `filteredSearchResults`/`startSearchTask`/`resetSearchControls`/etc. had any caller). Wired
      it into the active search path: (a) `resultsList` now renders `filteredSearchResults` instead
      of raw `searchResults`; (b) added `dictionarySearchFilterMenu` (sort: Relevance/Common First/
      A-Z, "Common Words Only" toggle, per-POS submenu, Reset) exposed via a context-aware trailing
      funnel that replaces the note/list funnel while a query is active; (c) `runDictionarySearch`
      now calls `pruneUnavailableSearchPartsOfSpeech()` after results land. DONE: POS, commonness,
      sort (incl. common-first ≈ frequency-ordered), the explicit JLPT-level filter (N1–N5
      picker in `WordsFilterView.swift`, backed by `jlptLevel`), AND now the frequency-threshold
      control: `DictionaryFrequencyTier` (Any / Top 5k / 10k / 20k by JPDB rank) as a picker in
      `dictionarySearchFilterMenu`, applied in `filteredSearchResults` via `entry.jpdbRank`
      (a finer usage-frequency axis than the JMdict `isCommonSearchEntry` flag). (The old cleanup
      note here is discharged: `searchResultsContent` and `startSearchTask` are already gone, and
      `DictionarySearchResultRow` is live — used by the Browse Frequency/Proficiency views.)
- [x] **Kanji-content filter for the saved-words list (All / Kanji Only / No Kanji)** — Done
      2026-06-30. New `WordsKanjiFilter` enum (`WordsView.swift`) persisted via
      `@AppStorage("savedWordsKanjiFilter")`, exposed as a segmented picker in its own "Kanji"
      section of `WordsFilterView` (orthogonal to the single-value "Show" scope — composes with
      it, e.g. Favorites + Kanji Only). Applied in `visibleWords` via
      `ScriptClassifier.containsKanji($0.surface)`; saved-kanji rows are hidden under "No Kanji"
      (they're kanji by definition). Note: hoisted the filter sheet + its sort/kanji bindings into
      `filterSheet`/`sortOrderBinding`/`kanjiFilterBinding` computed props to keep the `WordsView`
      body within the Swift type-checker's budget (a single extra inline binding tipped it over).
- [x] alternateSpellings(): include kanji variants — extracted from `WordDetailView` to `Kioku/Words/WordVariants.swift` so it's unit-testable; now surfaces both kanji-form and kana-form alternates (was kana-only), filters out `oK`/`sK`/`ok`/`sk` archaic + search-only forms, keeps irregular (`iK`/`ik`) variants. Pinned by `WordVariantsTests.swift` (6 tests). The previous `count > 1` noise-suppression gate is dropped — for kanji-bearing surfaces, even a single alternate is informative now that kanji variants are included. Pure-kana saved surfaces still return [] (false-uniqueness guard preserved).
- [x] CSV import: explicit option to fill kanji from the dictionary when the surface column is
      missing — Done 2026-07-01. `CSVImport.enrich` no longer silently substitutes kanji: a new
      `fillKanjiFromDictionary` flag (threaded through `fillMissing`) defaults OFF, so a
      surface-less row keeps its supplied kana (or the dictionary reading) as the surface instead
      of the kanji headword. A "Fill kanji from dictionary" toggle in `CSVImportView` opts in and
      re-parses the preview on change.
- [x] **Related words should be links to those words** — Done 2026-06-29 (`2f87902`). Tapping a
      Related Words / Synonyms row now opens a nested `WordDetailView` for that entry via
      `presentedRelatedSavedWord` (an ephemeral `SavedWord` built from the `DictionaryEntry`), and
      records the target to History like every other lookup entry point (`WordDetailView.swift:40-44,
      547-574, 734`). Related forms / kanji-family / synonyms are now browsable, not dead-ends.

## Study & Review

- [ ] **Note learning-coverage screen** — a per-note view that organizes all words in a note
      first by **level** (JLPT N5…N1, plus an unknown/no-level bucket), then within each level by
      **how well studied** (study mastery, e.g. New / Learning / Due / Learned from the SRS state
      in `ReviewStore`/`ReviewWordStats`). Goal: a visible progress surface to work toward full
      learning coverage of a note (e.g. per-level "12/18 learned" bars, a note-wide coverage %).
      Data is already available — words-in-note via `sourceNoteIDs`, JLPT via
      `dictionaryStore.jlptLevel(for:)`, mastery via `reviewStore` (`isLearned`/`isDue`/`stats`).
      Open design Qs: where it lives (Read-tab note action vs Words-tab note scope vs Learn tab),
      what the mastery buckets are exactly, and whether tapping a bucket starts a study session
      scoped to it. Brainstorm before building.
- [x] Spaced repetition scheduling — basic streak-based SRS shipped (`SRSScheduler.swift` + `ReviewWordStats.swift`: due dates, `consecutiveCorrect`, interval ladder). FSRS-style ease-factor algorithm is a possible future upgrade, not yet implemented.
- [x] Auto clipboard paste/search (`ClipboardLookupCoordinator.swift`, wired in `ContentView.swift`)
- [x] **Restore the kana chart as a Learn tab** — Done 2026-06-04. Brought back the
      `Kioku/Learn/KanaChart/` files (+ a new `KanaChartData.swift`) and wired `KanaChartView`
      as a fourth `LearnPage.kanaChart` in `CardsTabView.swift` (flashcards → multipleChoice →
      cloze → kanaChart), inserted into `LearnPagerView`'s HStack and dot overlay. The pager's
      `clampedIndex` guard makes the page-count bump safe against a stale persisted index — no
      migration needed. Builds clean.
- [x] **Fix the swipe animation between Learn pages** — Done 2026-06-02. Root cause: the
      page offset read `pageIndex` from `@AppStorage`, whose writes don't reliably animate
      inside a `withAnimation` transaction, so the `-pageIndex*width` term jumped a full page
      while `dragOffset` sprang → snap/teleport. Fix in `CardsTabView.swift`: drive the
      offset from a plain `@State pageIndex` (animates reliably) and mirror it to
      `@AppStorage` via `.onChange` (persistence as a side effect). Also added edge
      rubber-banding (0.3× damping past the first/last page) so the ends resist instead of
      sliding into blank space.
- [x] **Multiple-choice study mode in the Learn tab** — Done 2026-06-02:
      `Kioku/Learn/MultipleChoice/MultipleChoiceView.swift`, added as the second `LearnPage`
      (`flashcards → multipleChoice → cloze`) and inserted into `LearnPagerView`'s HStack.
      Modeled on `FlashcardsView`: home (reused `FlashcardNotePicker` — de-`private`d — +
      `FlashcardScope` + direction picker + count gate) → quiz → summary. Two directions
      (`日本語 → English`, `English → 日本語`). The question pool is resolved once at session
      start via the same `fetchWordDisplayData` path the cards use, then questions assemble
      synchronously; correct→`reviewStore.recordCorrect`, wrong→`recordAgain` (shares SRS +
      lifetime accuracy with flashcards). Objective grading with green/red feedback + Next.
      Gated at ≥4 words in selection. Emits the `CardsPageDotsHidden`/`StudySessionActive`
      preferences so the pager locks swipe + hides dots mid-quiz.
      - **Deferred:** dictionary-fallback distractors when the saved-word pool has fewer
        than 4 distinct answer-side strings. Today distractors come only from the pool, so a
        thin/duplicate-meaning selection yields 2–3 options instead of 4 (still valid, just
        easier). Wire dictionary-sampled distractors (random common entries of the same POS)
        as a follow-up if the small-pool case proves common.
      - **Enhancements (2026-06-02):** added a **Mixed** direction (per-question, seeded by
        entry id) and a question-count cap (numeric field, blank/0 = all) with swipe-down +
        keyboard-Done dismissal. Fixed answered-state feedback to paint explicit green ✓ /
        red ✗ fills (was washed out by `.disabled` greying — switched to `allowsHitTesting`).
- [x] **Standardize the three Learn start screens** — Done 2026-06-02. New
      `Kioku/Learn/LearnHomeScaffold.swift`: `LearnHomeForm` (Form + a uniform prominent Start
      section), `LearnHomeTitle` (shared principal toolbar title), and `LearnCountField`
      (shared session-size numeric field). All three home screens (Flashcards, Multiple
      Choice, Cloze) render through them; navigation models stay per-host (Flashcards/MC share
      their stack with the in-place session, Cloze pushes via `navigationDestination`).
      Unified the direction controls onto shared `StudyDirection` (日本語→English /
      English→日本語 / Mixed) and `StudyJapaneseForm` (原文 / 漢字 / かな) axes
      (`Kioku/Learn/StudyDirection.swift`) — Flashcards' old combined 6-way enum is gone;
      both modes now show the identical Direction + Japanese pickers and both have a count
      field. Flashcards' 漢字 form uses the true dictionary kanji headword (distinct from
      原文, the encountered surface).
- [x] **Full bidirectionality for flashcard directions** — `FlashcardCardDirection`
      (`FlashcardsView.swift`) now offers six directions: 原文→English / English→原文,
      かな→English / English→かな, 漢字→かな / かな→漢字. Done 2026-06-02: refactored
      `FlashcardCard.swift` from two duplicated per-direction `switch`es into a
      `FlashcardFaceContent` model (`encounteredSurface` / `kana` / `kanjiWithReading` /
      `english`) with a `faces(for:)` mapping table + single `faceView(_:)` renderer, so
      adding directions is a one-row change. Production reverses answer in Japanese,
      revealing the kanji headword with the kana reading stacked beneath ("inclusion of
      both"). Direction picker changed from `.segmented` → `.menu` (six multi-char labels
      don't fit a segmented control). `direction` stays `@State` (defaults to
      かな→English), so no persistence migration.

## Kanji

- [x] Dedicated kanji discovery tab/screen (`RadicalInputView()` sheet in `WordsView.swift`, "Find kanji by radical" toolbar button)
- [~] Full kanji metadata support (radicals, readings, components) — Partial (confirmed
      2026-06-30). `KanjiInfo` carries radical (Kangxi number), stroke count, on/kun readings,
      meanings, JLPT level, and frequency, all rendered in `KanjiDetailView`. STILL MISSING: a
      kanji **component/decomposition tree** — `KanjiInfo` has no component field; only radical
      *search* (`RadicalInputView`) exists, not per-character decomposition.
- [x] Handwriting input and stroke order (Zinnia handwriting recognition + KanjiVG stroke-order animation shipped; radical input also shipped)
- [x] Kanji of the day feature — Superseded by the Word of the Day system
      (`WordOfTheDayScheduler.swift`, `WordOfTheDayNavigation.swift`, `WOTDDiag.swift`,
      notification deep-links). The daily-feature decision landed on WOTD; a separate
      kanji-of-the-day isn't wanted. Closed 2026-06-30.
- [x] **Render on'yomi in hiragana, not katakana** — Done. `KanjiDetailView` folds on'yomi to
      hiragana at display time via `info.onReadings.map(KanaNormalizer.katakanaToHiragana)`
      (`KanjiDetailView.swift:50-57`); KANJIDIC2 source data stays canonical katakana (still used
      for furigana rendering). Kun'yomi already render in hiragana.
- [x] **Examine the `shouji` project for fun kanji-decoration ideas** — Superseded/closed
      2026-06-30. Kioku already ships a mature per-kanji decoration system
      (`KanjiDecoration+Abstract/Canvas/Particles/Nature.swift`, wired into the detail sheet
      background at `KanjiDetailView.swift:112` via `KanjiDecoration.view(for:)`). The
      inspiration this exploration item was meant to seed has effectively already landed, so
      it's no longer an open research task.

## Audio & Alignment

- [x] Expand karaoke alignment benchmark dataset and add CI evaluation job
      (`AlignmentQualityTests.swift` runs in `tests.yml`; 16 SailorMoon songs aligned via stable-ts large-v3)
- [~] Native human audio pronunciation dataset support (beyond TTS) — Deprioritized (don't-care
      2026-06-30). Groundwork now exists: the Human Japanese dataset carries per-word
      `SoundFilePath` audio keys (in the `human-japanese` project's `hj.db`/`hj.tsv`), a candidate
      seed if revisited. Not actively pursued.
- [x] Vocal-vs-instrumental detection — Addressed at alignment time rather than via real-time
      Sound Analysis. `SwiftWhisperAlign`'s `NonSpeechDetector` + `AlignmentNonSpeechCueBuilder`
      detect audible-non-vocal gaps and build the ♪ cues, and onsets are clamped to vocal at
      alignment time (see the lyric-alignment vocal-clamp work). The `SNClassifySoundRequest`
      real-time route in the original note is unnecessary; no in-app real-time audio analysis
      needed. Closed 2026-06-30.
- [x] Audio-level silence detection — Closed 2026-06-30. Same goal as the vocal-detection item
      above ("don't highlight when nothing is sung"), already met by the alignment-time
      `NonSpeechDetector`/vocal-clamp. The real-time `averagePower` hysteresis route is a distinct
      mechanism for the same now-solved problem; not pursued.
- [x] Unified ResolvedCue data model — Done. `SubtitleCue` now owns its character checkpoints
      inline (`SubtitleCue.swift:10-22`: `checkpoints: [CueCharTiming]`), collapsing the former
      parallel `cues` + `cueTimings: [Int: [CueCharTiming]]` pair. The index-keyed binder output
      is folded into each cue at load via `CueCharTiming.applyingCheckpoints(_:)`
      (`CueCharTiming.swift:22-28`); the legacy `[Int: [CueCharTiming]]` typedef remains only as
      the binder's intermediate. Consumers query the single source.
- [x] Fix karaoke trace ~150-200ms lead — Done. `AudioPlaybackController` reads
      `AVAudioSession.sharedInstance().outputLatency` and subtracts it from `player.currentTime`
      for cue alignment (`AudioPlaybackController.swift:354-359`), compensating the ≈10-50ms
      wired / ≈100-200ms Bluetooth output-buffer lead.
- [x] **Real-time SRT editing in the lyric view** — Done. `ReadView+LyricCueEditing.swift`
      implements the full in-place editing surface: `LyricCueEdit` enum (setStart/setEnd,
      setStart-with-ripple, set-to-ms, word-level realign, realign-all,
      set-word-start/end-to-playhead) applied by `applyLyricCueEdit(_:)`, persisted via
      `NotesAudioStore.shared.saveCues()` with live `AudioPlaybackController.updateCues(_:)`
      (no playback stop). The persistent top row in `LyricsView` (`LyricsView.swift:27-30`)
      emits the intents. The "Unified ResolvedCue" dependency above is also satisfied.
- [ ] **Reconsider: import subtitles as a note, then extract words the usual way?**
      Open design question, not yet decided. Today subtitle import is its own pipeline —
      parse (`ASSParser`/SRT) + optional `JimakuProvider` fetch, precompute segmentation at
      import time, and produce a note carrying an `audioAttachmentID` with cues/SRT in
      `NotesAudioStore`, plus a subtitle-specific vocab path. That's a parallel track to the
      normal flow where a note's `content` is segmented in ReadView and words are saved via
      the standard tap/extract → `WordsStore` path. Question is whether subtitle import should
      just drop the cue text into a regular note's `content` (keeping the audio attachment +
      timing for karaoke) and let the ordinary note→segmentation→save flow handle vocab —
      collapsing two code paths into one and removing the bespoke subtitle vocab picker.
      Trade-off to weigh: the dedicated path preserves per-cue structure (line boundaries,
      timing) that a flat note `content` blob would lose, which the karaoke/alignment views
      depend on; any unification must keep cue structure for audio even if vocab extraction
      goes through the common path. Decide before investing further in the subtitle vocab UI.

## Settings

- [x] Adjust ruby typography settings (spacing, padding) — `SettingsView.swift:17` `furiganaGapKey` + sliders for `furiganaGap`, `kerning`, `lineSpacing`
- [~] Default to Japanese IME where appropriate — Partial 2026-06-30. The custom-reading prompt
      now defaults to the Japanese keyboard via `JapaneseTextField`
      (`Kioku/Read/Lookup/JapaneseReadingPrompt.swift`). Still lacking Japanese-IME defaults:
      list-name fields (`WordsFilterView`/`WordsBatchListView`/`CSVImportView`/`SubtitleImportView`),
      the particle-tag editor (`SettingsView.swift:885`), and the personal-note field
      (`WordDetailView`). URL/number fields are correctly exempted (`.keyboardType(.URL/.numberPad)`).
      A reusable `JapaneseTextField` SwiftUI wrapper applied to these text fields would close it.
- [x] Clipboard behavior settings — `ClipboardSettings.swift` defines `autoDetectKey` + `defaultAutoDetect = true`; new "Clipboard" section in `SettingsView` toggles it. `ClipboardLookupCoordinator.checkClipboard()` short-circuits before any pasteboard read when off, so iOS's "Pasted from" notification doesn't fire for users who turn it off. Coordinator's `init(defaults:)` takes an injected `UserDefaults` so the gate is testable; pinned by 4 tests in `ClipboardLookupCoordinatorTests.swift`.

## Ship Readiness

- [x] Hide/gate debug section and diagnostic toggles from release builds
- [x] Add explicit pre-import confirmation for backup restore
- [x] Progressive disclosure in dictionary detail UI (`DisclosureGroup` in `WordsView+Search.swift`, `SongLineCard.swift`)
- [ ] Add UI smoke tests for core user loop (notes, lookup/save, study, backup)
- [ ] Split Settings into Basic vs Advanced (move advanced controls behind secondary screen)
- [~] Accessibility pass — Partial (re-confirmed 2026-06-30). VoiceOver labels are well covered
      (79× `.accessibilityLabel`), and `@ScaledMetric` is used in one place (`ClozeStudyView.swift:11-13`,
      blank sizing relative to `.title3`). But Dynamic Type adoption is essentially absent app-wide —
      text sizing elsewhere is driven only by the manual typography sliders, not the system Dynamic
      Type trait — and a contrast audit still remains.
- [~] App Store packaging artifacts and release QA checklist — Partial. `docs/APPSTORE.md` holds
      the full submission kit (name, description, keywords, age rating, privacy questionnaire,
      export compliance, review notes). Still missing: a dedicated release/QA checklist file and
      any release automation (only `ci_post_clone.sh` + `tests.yml` exist; no `release.yml`).
- [x] Credits/About screen with dataset attributions — `Kioku/Settings/AboutView.swift` pushed from a new "About" row in `SettingsView`. Renders version + 8 dataset entries (JMdict, KANJIDIC2, Tatoeba, JPDB Frequency, wordfreq, UniDic pitch accent, RADKFILE2/KRADFILE2, Tegaki-Zinnia) and 9 library entries (SwiftWhisper, USearch, SwiftLCS, swift-subtitle-kit, SwiftSubtitles, CodableCSV, swift-audio-marker, TextFormation, zinnia-swift), each with license + source URL. Data lives in `Attributions.swift` (separate from view for testability); 5 tests in `AttributionsTests.swift` regression-guard against accidentally dropping an entry.

---

# Infrastructure

Tests, tooling, and CI carry-over. Lower-visibility than product work but each
item maps to an invariant warning or a known fragility.

## Store-level test coverage

Persistence stores needing matching `*Tests.swift` files. Invariant 8 fires a
warning for each on every commit / push / CI run. Pattern established in
[HistoryStoreTests.swift](../KiokuTests/HistoryStoreTests.swift) (UserDefaults-backed)
and [NotesStoreTests.swift](../KiokuTests/NotesStoreTests.swift) (file-backed via
injectable `TestFileManager`).

- [x] **WordsStore** — saved-word lifecycle; data-loss risk if broken. Done 2026-05-25: 29 tests in `WordsStoreTests.swift`, covering CRUD, list membership, selections, move, reload, and the rich `toggle(...)` semantics (note attribution, encountered-surfaces set, card-removal-only-when-both-empty). One latent bug fixed: `SavedWordStorage.normalizedEntries` was re-constructing the merged `SavedWord` without passing `encounteredSurfaces`, which the init defaults to `Set([surface])` — so every encountered form from both inputs was silently discarded. No production path currently feeds duplicates through normalize (toggle/replaceAll callers produce unique IDs), but the helper's contract is "coalesce duplicates without data loss" and any new caller (CSV import, hand-edited backup, future bulk add) would hit it. Pinned by `testNormalizedEntriesMergesEncounteredSurfacesFromDuplicates`. Pattern note: `SavedWordStorage` already took `userDefaults: UserDefaults = .standard`; the change was to thread that through `WordsStore.init` and the `persist`/`reload` callers. Tests inject `UserDefaults(suiteName: "kioku-words-tests-\(UUID().uuidString)")` and clean it up in tearDown.
- [x] **SavedWordStorage** — implicitly covered by the WordsStoreTests above (the suite tests `normalizedEntries` directly, plus exercises every disk-roundtrip path through WordsStore as a host). The store-test invariant in `validate_invariants.sh` will still flag this file as untested because the matcher looks for a `SavedWordStorageTests.swift` filename specifically — worth either adding a one-line stub that delegates, updating the matcher to accept "covered by sibling", or accepting the warning as known-suppressed.
- [x] **NotesAudioStore** — audio attachment metadata for notes. Done 2026-05-24: 19 tests in `NotesAudioStoreTests.swift`. Two bugs surfaced and fixed in the same change: (a) `importAttachment` was passing `audioFilename` ("song.mp3") as `saveSRT`'s `preferredFilename`, which made the SRT inherit the audio extension and overwrite the audio bytes; fixed by routing through `preferredSubtitleFilename(forAudioFilename:)`. (b) `readableFilename` split the storage stem on the first hyphen to reverse `{uuid}-{base}`, but UUIDs themselves contain 4 internal hyphens, so the function returned a UUID-tainted string for any preserved-basename file — silently broke `audioBaseName`-driven TextGrid sibling matching in `BulkImportPlanner`; fixed by detecting the UUID prefix as fixed-width (36 chars) + validity.
- [x] **WordListsStore** — `WordListsStoreTests.swift` covers list membership + dedup.
- [x] **SongBreakdownStore** — `SongBreakdownStoreTests.swift` + existing `SongBreakdownRecoveryTests` cover round-trip and recovery.
- [x] **ReviewStore** — `ReviewStoreTests.swift` covers review metrics persistence.
- [x] **DictionaryStore** — credited to `LexiconTests` (read-only store, exercised through every lookup test). Invariant-checker script updated to retire the warning; store-test warnings 5 → 0.

Estimated effort: 30–60 min per store using the established pattern.

### Pattern note for the remaining stores

`NotesAudioStore` followed `NotesStore`'s injection pattern adapted for a singleton: keep `static let shared` for production wiring, add a non-private designated `init(audioDirectory: URL)` so tests scope to a per-case temp dir. When the production code is already pure-singleton (`static let shared = ...; private init()`), the minimal change is to (a) extract the production base URL into a `private static func defaultXxx()` helper, (b) make the init public/internal, take the base URL as a parameter, and (c) have `.shared` call the new init with the default. Tests then construct fresh instances against `FileManager.default.temporaryDirectory.appendingPathComponent("kioku-…-tests-\(UUID().uuidString)")` and tear down the dir in `tearDown`.

## CI / tooling watch list

Things that aren't broken but could become so. Not actionable today — just worth a periodic look.

- [ ] **`macos-26` is a GitHub Actions preview runner.** If GH deprecates the preview image before iOS 26.5 reaches `macos-15`, CI breaks until we react. Fallback path: `xcrun simctl runtime install` to add iOS 26.5 to `macos-15`, or accept skip-testing the affected suites.
- [ ] **Coverage step-summary parsing.** The Python jq pipeline in `tests.yml` reads `coveredLines` and `executableLines` from `xccov view --report --json`. If Xcode changes the xcresult JSON shape, the summary silently emits nothing (the `if [[ ! -d ... ]]` guard would not catch it). Worth verifying after each Xcode major.
- [ ] **Submodule SSH-to-HTTPS rewrite assumes the SwiftWhisper fork stays public.** If it's ever flipped to private, CI breaks; either provision a deploy key or pin to a fork URL that stays accessible.

## Watch list — degrading since last triage (2026-05-25)

- ⚠️  **`print()` call count: 66.** Down from 101 (and from 77 mid-session) via the os.Logger migration pass + the preventive splits. Remaining are concentrated in legacy diagnostic paths; route through `os.Logger` (subsystem-tagged so they're filterable in Console.app) opportunistically when touching the surrounding code.
- ✅ **File-size guardrail cleared (2026-05-25).** Splits landed: `ForcedAlignmentProvider.swift` 819 → 580 (extracted `AlignmentTimestampMath`, `AlignmentNonSpeechCueBuilder`, `WhisperAudioFrameDecoder`); `ReadView+AudioTranscription.swift` 722 → 293 (extracted `AudioTranscriptionHelpers`); `SubtitleEditorSheet.swift` 758 → ~660 (extracted `SubtitleEditorTimingTools`); `ReadView+LLMCorrection.swift` 741 → 405 (extracted `LLMCorrectionDiagnostics`). `ReadView+Segmentation.swift` 735 still pending the preventive split.
- ⚠️  **`ReadView` extension sprawl — the architectural one.** See the dedicated section below.
- ✅ **`SWIFT_VERSION = 6.0`** (was 5.0) — strict-concurrency now active. Done 2026-05-25 across 13 src files + 14 test targets: nonisolated logger/statics/callbacks, `Sendable` conformances on dict types, MainActor isolation for tests. 373/373 passing.
- ✅ **Force-unwrap audit done** — each surviving `!` either has a one-line `// invariant: …` justification or has been replaced with safe unwrap.

## ReadView decomposition (architectural, deferred)

**Problem.** 19 `ReadView+*.swift` files in `Kioku/Read/` total 6,427 LOC and
all live as extensions on the same `ReadView` struct, sharing one `@State`
namespace. The folder layout (`Segmentation/`, `Lookup/`, `Audio/`, `LLM/`,
`Furigana/`, `CoreTextRenderer/`) implies subsystem ownership that the type
system doesn't enforce: a Lookup file freely reads Segmentation `@State`, an
Audio file freely toggles Furigana `@State`, and any state-property rename is
a 19-file diff. Pure-helper extractions (the preventive splits landed
2026-05-25 — `LLMCorrectionDiagnostics`, `AudioTranscriptionHelpers`,
`SubtitleEditorTimingTools`) get small things off the host file but don't
touch the underlying coupling. This is the one structural debt that will keep
compounding if deferred.

**Brainstorm before starting.** Two plausible directions, neither obviously
right:

1. **One `@StateObject ReadViewModel`.** All ReadView state moves to a single
   `@MainActor final class ReadViewModel: ObservableObject` that the View
   holds. Extensions become methods on the model. Win: state ownership is now
   one type with `private` properties; extensions in other files can't reach
   in without going through `internal` properties (forcing intentional
   exposure). Lose: the model becomes a 6k+ LOC class with the same coupling,
   just relocated; the @Published property explosion may regress SwiftUI body
   invalidation behavior.

2. **Per-subsystem view models.** `SegmentationViewModel`, `LookupViewModel`,
   `LyricsViewModel`, `LLMCorrectionViewModel`, etc., each owning its own
   slice of state, composed by `ReadView` as `@StateObject` properties. Win:
   subsystem coupling becomes explicit (Lookup that wants Segmentation state
   must take a reference); each model is small enough to reason about. Lose:
   shared state that genuinely crosses subsystems (selected segment location
   read by Lookup, Lyrics, AND Furigana; current cue time read by Lyrics AND
   Furigana) needs a deliberate cross-model contract — probably a slim
   `ReadCoordinator` or a few `@Published` projections — that's worth getting
   right rather than improvising mid-refactor.

**Recommended approach.** Do a brainstorming session first (worktree or
scratch branch, not main). Pick one subsystem (`Lookup` is probably smallest)
and extract its view model end-to-end as a probe. Measure: did the host file
shrink? Did the new view model's API surface stay tight? Did the cross-subsystem
state requirements come into focus? Use the answer to commit to direction #1
or #2 for the rest.

**Until then.** Continue the pure-helper extraction pattern when files cross
the 700-line band — that's worked well (4 splits landed today, 19 files still
share state but each one is now tractable to read). The architectural fix is
the larger version of the same conversation, not a different one.

## Verified clean (no follow-up needed)

For reference — these were checked during the recent infra pass and have no remaining work:

- ✅ Zero `// TODO` / `// FIXME` / `// XXX` / `// HACK` / `// TBD` comments anywhere in `Kioku/`, `KiokuTests/`, or `SwiftWhisperAlign/`. (Last verified 2026-05-24.)
- ✅ No vestigial root-level config (`package.json` / `node_modules` cleared).
- ✅ `AGENTS.md` aligned with current invariants (file-size, store-test, setup.sh).

---

# Resolved / pinned

Characterization tests in `KiokuTests/SegmentationKnownGoodTests.swift` (and
siblings) lock in behavior that previously regressed. Listed here so a new
session can grep before re-investigating a "broken" case.

## Reading-specific cases (now pinned)

- ✅ **消してくれる** — reading けして (from 消す) pinned in `SegmenterIntegrationTests.swift`
- ✅ **抱かれ** — readings いだかれ / だかれ / うだかれ pinned by `testIdakare()` in `SegmentationKnownGoodTests.swift`
- ✅ **月色** — reading つきいろ pinned by `testTsukiiro()` in `SegmentationKnownGoodTests.swift`

## Segmentation cases (now pinned)

- ✅ つないだ → one segment, lemma つなぐ
- ✅ まけない → one segment, lemma まける
- ✅ その度 → one segment, lemma その度
- ✅ トキメク → one segment, lemma ときめく (katakana → kana iteration via expansion)
- ✅ しょげちゃうんだ → one segment, lemma しょげる
- ✅ かなえて → one segment, lemma かなえる
- ✅ プレイヤーズ → one segment, recognized via extras.json
- ✅ ティアーズ → one segment, recognized via extras.json
- ✅ 済まれないで → one segment, lemma 済む (passive + negative + linking で; added `passiveNegativeTeForms` rule set 2026-05-25 — 12 rules covering each v5 stem ending + v1 + vk + vs)
- ✅ かけましょ → one segment, lemma かける (〜ましょ volitional)
- ✅ ショーブ → one segment, lemma しょうぶ (katakana long-vowel expansion ョー → ょう; matches トキメク convention of katakana → hiragana lemma, not katakana → kanji)
