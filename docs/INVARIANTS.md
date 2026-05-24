# Subsystem Invariants

Falsifiable contracts each major subsystem promises to hold. Each invariant is
the kind of claim a regression test should pin: "for any input matching X, the
output must satisfy Y." When in doubt about whether a fix is correct, check it
against the relevant invariants — and if a fix could violate one, that's the
test it needs.

The process rule (per agreement, 2026-05-23): on subsystems that already have
test files, any bug fix that touches them must add or update a test. This doc
is the spec those tests are written against. Greenfield subsystems are exempt
until they're promoted onto this list with their first test file.

Format: each invariant has a claim, a one-line rationale (why violating it
breaks something users care about), and a current test-coverage status:
- ✅ pinned by an existing test
- ⚠️  partially tested (some cases, not all)
- ❌ not tested

Status snapshots are point-in-time and should be updated as tests land. The
goal is to drive everything to ✅.

---

## Alignment & Reconcile (`SubtitleEditorSheet.reconcileFromNote`, `OnDeviceLyricAligner`)

The reconcile pipeline takes (audio, current SRT, note text) and produces a
new SRT. It must be safe — never lose user-authored content — and predictable
— same input gives same output, and good inputs survive untouched.

1. **No-drop**: every non-blank, non-♪ line in the note text appears as text
   in at least one output cue, even if the aligner produced fewer cues than
   expected (force-fit fallback fills the rest).
   - *Rationale*: dropping a line is unrecoverable data loss from the user's
     point of view — the line existed in their note and silently vanished
     from the SRT.
   - *Status*: ✅ (`SubtitleReconciliationTests.testReconcilePipelineDropsNoLinesOnTotalMismatch`,
     plus `testUniformDistribute…` family for the force-fit safety net).

2. **Monotonic order**: output cues' note-line indices are non-decreasing
   when sorted by start time.
   - *Rationale*: cue order out of sync with note order breaks karaoke
     highlighting — the wrong line lights up.
   - *Status*: ✅ (`SubtitleReconciliationTests.testMatchAnchorsProducesMonotonicNoteLineIndices`).

3. **Anchor non-disturbance**: when an input cue matches a note line by text
   and is not adjacent to a gap window, its start/end timings in the output
   differ from the input by ≤ 1ms.
   - *Rationale*: users learn cue positions; arbitrary shifts during a
     targeted fix erode trust in the tool.
   - *Status*: ✅ (`SubtitleReconciliationTests.testMergePreservesNonConsumedAnchorTimings`).

4. **Idempotence on clean input**: when input SRT already has exactly one cue
   per note line with matching text and no gaps, reconcile produces a result
   identical to the input (same cues, same order, same timings).
   - *Rationale*: running reconcile on a finalized SRT should be a no-op;
     otherwise users can't trust it not to silently rewrite their work.
   - *Status*: ✅ (`SubtitleReconciliationTests.testBuildGapsReturnsEmptyForCompleteAnchorCoverage`).

5. **Force-fit completeness**: when a gap window of length L holds N expected
   lines, `uniformDistribute` returns exactly N cues whose combined coverage
   spans `[windowStart, windowEnd)`.
   - *Rationale*: per #1, lines must not be dropped; per user requirement
     2026-05-23, force-fit is the fallback when the aligner can't help.
   - *Status*: ✅ (`SubtitleReconciliationTests.testUniformDistribute…` × 5).

6. **Music preservation**: input cues recognized as non-speech (♪ markers)
   pass through to the output unchanged.
   - *Rationale*: ♪ markers reflect VAD-detected non-vocal audio; reconcile
     has no business adjusting them since it's working from text, not audio.
   - *Status*: ✅ (`SubtitleReconciliationTests.testMergePreservesMusicCuesUnchanged`).

7. **Anchor consumption is contiguous**: when a gap window consumes its
   preceding anchor, that anchor's original cue does not appear in the
   output; instead its text appears as the first cue in the gap's aligned
   output.
   - *Rationale*: keeping the original alongside the re-aligned version
     produces overlapping cues at the same range.
   - *Status*: ✅ (`SubtitleReconciliationTests.testMiddleGapConsumesPrecedingAnchor`,
     `testTailGapConsumesLastAnchor`, `testHeadGapDoesNotConsumeAnyAnchor`,
     `testMergeOmitsConsumedAnchors`).

8. **Cancellation cleanliness**: when the alignment task is cancelled
   mid-run, no partial result is committed to disk and the editor's
   `srtText` reflects the pre-run state.
   - *Rationale*: a partial reconcile is worse than no reconcile.
   - *Status*: ❌.

9. **Quality against ground truth**: on each fixture song, ≥95% of
   ground-truth cues have a matching output cue (same text) whose start
   time is within 500ms of the ground-truth start. Median start delta ≤
   200ms. No ground-truth cue is missing from the output. Tested on the
   in-app anchored Reconcile pipeline (the exact orchestration the editor
   sheet calls) against a stable-ts large-v3 oracle.
   - *Rationale*: the unit tests prove the plumbing — that we don't drop
     lines, that anchors aren't disturbed, that gaps consume their preceding
     anchor — but say nothing about whether the aligner *actually finds*
     the right timestamps. Quality regressions (model change, parameter
     drift, callback bug like today's TOCTOU race) need a quantitative
     check against a known-good output, not visual eyeballing.
   - *Status*: ⚠️ (`AlignmentQualityTests.testQuality_TsukiiroChainon`
     runs and prints BEFORE/AFTER metrics every CI cycle; no-drop hard
     gate passes; coverage/median thresholds wrapped in XCTExpectFailure
     while the in-app pipeline's current floor on 月色チャイのん is 29.4%
     coverage / 792ms median Δ — substantially better than the
     pre-reconcile baseline of 29.4% / 764ms with 3 missing lines).
   - *On the AlignmentQualityTests harness*: each fixture also asserts
     the no-drop guarantee directly. That's the only assertion not
     wrapped in expectFailure — dropping a line is a structural defect
     in the pipeline, not a timing-quality knob.

---

## Furigana Resolution (`ReadView+Furigana`, `FuriganaResolver`)

Furigana resolution merges three sources — dictionary lookups, user pins (LLM
corrections, manual edits), and synthesized concatenations from per-character
fragments. The invariants govern which source wins and when.

1. **Provenance order on same-range collisions**: at any (location, length),
   precedence is `dictionary > user-pin > synthesized`. Lower-precedence
   entries do not overwrite higher-precedence entries.
   - *Rationale*: established by the origin-tracking work (2026-05-23) —
     synthesized entries previously blocked dict replacements (the ものご-vs-
     ものがたり bug).
   - *Status*: ✅ (`ReadViewFuriganaTests.testApplyNewAnnotationsReplacesSameRangeSynthesizedEntry…`).

2. **Replace-on-overlap**: a new annotation whose UTF-16 range strictly
   contains existing narrower annotations supersedes those fragments — the
   fragments are removed and the wider span installed in their place.
   - *Rationale*: this is what collapses per-character furigana (もの+ご)
     into the compound (ものがたり) once the dict reading is available; the
     two-ruby-frame state from incomplete fragments is the failure mode.
   - *Status*: ✅ (`ReadViewFuriganaTests.testApplyNewAnnotationsReplacesFragmentedEntriesWithWiderCompound`).

3. **Span containment**: every furigana annotation's UTF-16 range falls
   entirely within its owning segment's range.
   - *Rationale*: annotations whose range extends past the segment crash
     CoreText layout or render at wrong positions.
   - *Status*: ⚠️ (implicit in `buildSegmentRanges` filter; no negative-case
     test).

4. **Decomposition-as-origin signal**: any wide entry whose value can be
   decomposed into a sequence of valid per-character dictionary readings is
   classified as synthesized (origin = .synthesized).
   - *Rationale*: enables migration of pre-gate poisoned synthesis output
     into the replaceable bucket.
   - *Status*: ✅ (`ReadViewFuriganaTests.testLocationsOfPresumedSynthesizedWideEntries…`).

5. **Synthesis triggers only on complete per-char tiling**: the synthesis
   pass produces a wide entry only when per-character fragments cover the
   kanji run exactly (no gaps, no overlaps).
   - *Rationale*: partial synthesis on incomplete input is the failure mode
     that produced the ものご bug.
   - *Status*: ✅.

6. **No annotation past edit**: when a segment's surface text changes via
   user edit, all furigana annotations within that segment's previous range
   are dropped.
   - *Rationale*: stale annotations on edited segments display in wrong
     positions or crash layout.
   - *Status*: ✅ (`ReadViewFuriganaTests.testPruneFuriganaForSegmentationDropsAnnotationsPastShortenedText`
     plus the existing split-case test).

---

## Segmentation (`Segmenter`, `Lexicon`, `ReadView+SegmentBuilding`)

Segmentation partitions source text into dictionary-aligned tokens. The
invariants govern coverage (no character orphaned) and user-intent persistence
(merges/splits aren't silently undone).

1. **Total coverage**: every UTF-16 unit in the source text belongs to
   exactly one segment in `segmentEdges`.
   - *Rationale*: gaps cause rendering glitches; overlap causes double-tap
     and double-color bugs.
   - *Status*: ✅ (`SegmenterIntegrationTests.testLongestMatchEdgesTileSourceWithoutGapsOrOverlap`,
     property-tested over a corpus; new fixtures just append to the corpus loop).

2. **Disjoint segments**: no two segments in `segmentEdges` overlap in their
   UTF-16 ranges.
   - *Rationale*: same as #1.
   - *Status*: ✅ (same test as #1 — the tile-walker catches both gap and
     overlap with the same `cursor == edge.start` assertion).

3. **User merge/split survival**: segments produced by user merge or split
   actions persist across text-unchanged recomputes (re-segmentation only
   redraws on text change, not on settings or dict updates).
   - *Rationale*: silently undoing user intent is the most damaging class of
     regression — the user can't tell the system "forgot".
   - *Status*: ⚠️ (`ReadView+Lifecycle` has comments referencing this;
     unclear how it's tested).

4. **Punctuation tap is noop**: tapping a segment whose surface is entirely
   whitespace or noise-class punctuation (per
   `ReadView+SegmentBuilding.isNoiseSegment`) does not open the dictionary
   lookup sheet.
   - *Rationale*: established UX contract — looking up "、" is never useful.
   - *Status*: ⚠️ (logic exists; no test for the tap handler).

5. **Lemma resolution is deterministic**: for any (surface, context),
   `Segmenter.preferredLemma(for:)` returns the same lemma every call within
   a single segmenter lifetime.
   - *Rationale*: non-determinism here causes furigana to flicker between
     readings on re-renders.
   - *Status*: ❌.

---

## Note Persistence (`NotesStore`, `NotesStoreTests`)

Notes hold user-authored content. The contract is data integrity above all.

1. **Round-trip identity**: for any valid note N, `load(save(N)) == N`.
   - *Rationale*: a save that loses any field is silent data loss.
   - *Status*: ⚠️ (`NotesStoreTests` covers core fields; not all optional
     fields verified).

2. **Atomic writes**: a `save(note)` call either commits the full new state
   to disk or leaves the previous version intact. Partial writes are not
   observable.
   - *Rationale*: a crash mid-save must not produce a half-written note
     file.
   - *Status*: ❌ (relies on `.atomic` write semantics; not explicitly
     tested).

3. **Schema-version forward compat**: when loading a note written by an
   older app version, unknown fields in the older format are preserved and
   round-trip back into the file unchanged.
   - *Rationale*: protects user data across app upgrades/downgrades.
   - *Status*: ❌.

4. **`replaceAll(with: [])` clears disk**: passing an empty array to
   `NotesStore.replaceAll` removes all note files from `Application
   Support/Notes`, not just the in-memory state.
   - *Rationale*: fixed 2026-05-23; the in-memory-only version left orphan
     files that re-loaded on next launch.
   - *Status*: ✅ (`NotesStoreTests`).

5. **Index consistency**: `_index.json` always lists exactly the note IDs
   for which a `<noteID>.json` file exists, in load order.
   - *Rationale*: index drift causes missing-from-list or duplicate-row
     bugs.
   - *Status*: ✅ (`NotesStoreTests.testIndexAndDiskFilesStayConsistentAcrossLifecycle`
     walks add → delete → replaceAll asserting both sides after each step).

---

## LLM Correction (`ReadView+LLMCorrection`, `SongBreakdownStore`)

LLM-driven corrections are user-authored overrides on derived data. They must
survive normal app lifecycle and not silently misapply.

1. **Persistence across reload**: a correction applied to a (note, segment,
   range) survives note close + app relaunch and is re-applied on note
   reopen.
   - *Rationale*: anything else is functionally useless.
   - *Status*: ❌.

2. **Override scope**: corrections apply only to the specific
   (note ID, segment surface, intra-segment range) they were authored for —
   never to a different note or to a different segment with the same
   surface.
   - *Rationale*: cross-note bleed of corrections is a confusing,
     hard-to-undo bug.
   - *Status*: ❌.

3. **Re-segmentation invalidation**: when a segment is split, merged, or its
   surface otherwise changes, corrections targeted at the prior segment are
   dropped (not silently transplanted to the new segment).
   - *Rationale*: transplanted corrections look like they applied correctly
     but are at the wrong position; users can't tell.
   - *Status*: ❌.

4. **Breakdown hash gates display**: the breakdown UI surfaces a "Regenerate"
   banner when `breakdown.sourceTextHash != hash(currentNoteText)`; it does
   not auto-invalidate the cached breakdown.
   - *Rationale*: established by `SongBreakdownStore` design — automatic
     invalidation would discard expensive LLM output on every trivial edit.
   - *Status*: ⚠️ (logic exists; not directly tested).

---

## Process

- **Test-with-fix** on subsystems listed above: any bug fix that touches them
  must add or update a regression test for the invariant being restored.
- **New invariants go here first**: when a fix reveals an implicit contract,
  write the invariant before writing the test.
- **❌ → ✅**: every status downgrade in a PR (test removed, invariant
  weakened) must be called out in the PR description; every upgrade
  (new test pinning a previously-❌ invariant) is a win to celebrate.
- **Subsystem promotion**: a greenfield subsystem joins this doc when it
  gets its first test file. Until then, it's exempt from the rule.
