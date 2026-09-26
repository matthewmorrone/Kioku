# Todo

Open Kioku work only. Finished items are deleted, not ticked; git history has them. Each entry is
written so a new session can pick it up cold.

## Features

- [ ] Quiz on next and previous words/lines
- [ ] Add manual/custom word creation and editing
- [ ] **Import a subtitle file straight to a note** — rewritten 2026-09-26 from an open design
      question. Today the Words tab's subtitle import (`SubtitleImportView`, also reached from
      Jimaku search via `SubtitleSearchView`) is a vocab-list flow: it segments the file, shows the
      extracted vocab, and saves the chosen words to a list. "Keep as note" is a side option: the
      note is only created when at least one word is saved (`performImport` returns early on an
      empty selection), and cue timing is dropped (the note gets the text and precomputed
      segments only). The feature: an "Import as note" choice that creates the note (title from
      the file name, precomputed segmentation, as today) with no vocab step, so you read it and
      save words with the normal tap / Extract sheet (which already uses the same
      `SubtitleVocabExtractor`). Keep the vocab-list flow as the other choice. Out of scope:
      pairing with audio. Notes → bulk import already pairs an audio file with its sibling
      `.srt` (`BulkImportPlanner`).
- [ ] **Real-time kanji-choice game mode** — pick the correct kanji as fast as possible; score
      on speed + accuracy in near-real-time (from app-usage backlog 2026-07-01). Needs a design
      pass (grilling) before building: question source (saved words? by JLPT/frequency?), distractor
      selection, timer/scoring model, round length, how it ties into `ReviewStore` (does a fast
      correct answer count as a review?). Sits alongside the existing MultipleChoiceView.
- [ ] **Karaoke vocab-probe mode** — planned 2026-07-02, spec'd via grilling. Reframed from a
      karaoke "score" into a **vocabulary probe**: sing over the instrumental, transcribe per
      section, and surface which *content words* you produced (known) vs missed (study
      candidates). Decisions: words-only (no pitch/timing); play HTDemucs instrumental
      (mix−vocals subtraction, cache both stems); per-section (♪/gap boundaries); post-hoc
      scoring; kana/mora word matching; content-words-only; a "Sing" mode inside `LyricsView`;
      transient recording; generate stem on demand; missed words → save/study, no SRS
      auto-mutation. Large multi-part build — pick up in a dedicated session. (A detailed
      4-phase TDD implementation plan existed at `docs/superpowers/plans/` and is recoverable
      from git history if wanted, but that workflow is retired — re-derive fresh instead.)


## Segmentation & Lookup

- [ ] **Dictionary rebuild pending for new `extras.json` entries** — シェノン (French *chaînon*,
      "link in a chain"; sung in 月色Chainon) was added 2026-09-26 and is inert until the next
      from-source rebuild. Batch it with the next dictionary change: `Resources/generate_db.py`,
      bump `releaseTag`/`expectedSHA256` in `DictionaryDownloadManager.swift`, then
      `scripts/publish_dictionary_release.sh`, and re-measure with `scripts/segmentation-eval`.
- [ ] **`DictionaryTrie.Node.children` is `[Character: Node]` — consider a scalar-keyed
      dictionary instead.** Investigated 2026-07-13 while chasing cold-start latency
      (`StartupTimer` measured `trie population (456249 records)` at ~1005ms). `Character` is a
      variable-width grapheme-cluster type; hashing/equality has to account for Unicode
      grapheme-boundary edge cases that essentially never apply to dictionary/user text (kanji/
      kana are almost always single Unicode scalars). Switching `children` to a scalar key
      (e.g. `[UInt32: Node]` keyed by `Unicode.Scalar.value`) would speed up not just the
      one-time trie build but every lookup during live segmentation too (`contains`,
      `partOfSpeech`, `ipadicContextIDs`, `hitMeta`, `prefixScan`, `prefixHitScan` — 8 call
      sites total, all contained to `Kioku/Dictionary/DictionaryTrie.swift` +
      `Kioku/Dictionary/Node.swift`, nothing else touches `.children`). Estimated payoff is
      modest and uncertain without benchmarking — maybe 200-400ms off the trie-build step,
      nothing for `fetchSurfaceData` (a separate function; its query plan already uses
      `idx_kanji_text`/`idx_kana_text` reasonably well).
      Correctness risk: multi-scalar Characters (rare combining-mark sequences) would need
      either an NFC-normalization safety net before scalar iteration, or accepting the
      near-zero real-world risk that Japanese dictionary/user text is already NFC-precomposed.
      Not started; on hold until the user says go (2026-09-26). Measure cold start with
      `StartupTimer` before and after.
- [ ] **Context-chosen readings for homographs (様 さま/よう, 方, 何, 間, 上…)** — added 2026-09-24.
      Furigana picks a reading by surface alone: `FuriganaResolver.readingForSegment` takes the
      top-ranked hiragana reading, so a lone 様 is さま even in の様止まらず (よう). Measured
      2026-09-24 against the Tatoeba gold's marked readings (held2k + fresh5k, 4,551 multi-reading
      kanji segments): the frequency pick is right 96.5%. Tried and rejected:
        • Reading from a dictionary phrase around the segment (様に → ように), used whether or not
          the phrase won the path search: 18 changes on held2k, mostly wrong (今日は → こんにち ×8,
          後に → のち, 外に → ほか). Phrase POS doesn't separate good from bad (外に exp, 度に adv).
        • MeCab/IPAdic's in-context reading where it is one of ours: 95.5% — fixes 87 (counters and
          suffixes: 人 にん, 中 ちゅう, 分 ふん, 様 よう) but breaks 131 (後 のち, 金 きん, 間 ま,
          昨夜 さくや, 今 こん). A "trust MeCab only for counters/suffixes" filter would be fitted to
          this gold — declined.
        • Per-reading lattice edges from JMdict POS: JMdict tags さま (51237) `suf`/`n` and よう
          (56931) `n-suf,n`, and its よう-様 is the "way of doing" sense — the "like" sense lives
          only in 様に / 様な / 様だ / 様です. IPAdic context IDs are per surface (all 様 share 1314).
      The eval can't settle 様: Tatoeba prose writes ように in kana (286 sentences) and has 3 bare
      kanji 様. What shipped instead: merging segments takes the merged word's dictionary reading
      (の様に → よう; `markFuriganaReplaceable`), and dictionary-v12 adds の様 (のよう) as an extra.
      Reopen only with lyric text whose readings are marked — the 12 alignment-fixture songs are
      the candidate source.


## Audio & Alignment

- [ ] **"Find correct timestamp" repair tool for a mismatched lyric cue** — reported 2026-09-02:
      when a user flags a `SubtitleCue` whose audio doesn't match its text, offer a "search the
      song for where this line actually is" fix. **Premise updated 2026-09-26:** the OOM / ~101 s
      median-error full-song path this was written against is gone. The shipped aligner already
      computes MMS emissions over the whole song, and Debug builds dump them
      (`Documents/ctc-debug/<key>.emissions.f32`), so step 1 below is free. What's left is a small
      phrase-spotting search over emissions that already exist:
      1. Reuse the cached per-frame emissions for the song (no new encoder pass).
      2. Slide the mismatched cue's known text as a CTC-scored window across those frame outputs;
         take the top-N score peaks, where N = how many times that exact line occurs in the song's
         known lyrics (repeats are the normal case for song lyrics, not an edge case).
      3. **Repeated-line disambiguation**: pair the N peaks to the N known occurrences of the line
         by time order — peaks sorted by position, occurrences sorted by their position in the
         lyric sequence, paired off — deterministic, no fuzzy tie-break needed for the common case.
         Fall back to bounding candidates by the neighboring (already-correct) cues' timestamps if
         the peak count doesn't match the expected occurrence count (e.g. a backing-vocal echo
         producing an extra false peak).
      Considered and rejected: predicting a spectrogram from the target text (TTS-style
      text→mel-spectrogram) and cross-correlating it against the real song's spectrogram — sung
      audio's pitch/rhythm/timbre diverges too far from a synthesized (likely spoken-register)
      reference for raw spectral cross-correlation to be reliable. CTC's phoneme-probability
      scoring is acoustic-identity-invariant in a way raw spectrogram matching isn't, so it should
      generalize better here. Should reuse `CTCAlignmentCore`/`SwiftWhisperAlign` infra rather than
      new signal-processing code, and can be prototyped on the Mac with `scripts/alignment-replay`.

## Testing

- [ ] **UI automation tests for the core loop** (notes, lookup/save, study, backup). Store-level
      coverage exists (`CoreLoopSmokeTests`, `AppBackupValidatorTests`); nothing drives the actual UI.
      The `KiokuUITests` target already exists in the project with no source files (the template
      tests were removed in `372c42a`), so this means adding a `KiokuUITests/` folder with XCUITests.
      They run on the phone or in CI; this Mac has no simulator runtime.


## CI watch list

- [ ] **`macos-26` is a GitHub Actions preview runner.** If GH deprecates the preview image before iOS 26.5 reaches `macos-15`, CI breaks until we react. Fallback path: `xcrun simctl runtime install` to add iOS 26.5 to `macos-15`, or accept skip-testing the affected suites. (Left as a watch — no clean proactive code fix short of pre-installing a runtime, which is slow and unwarranted while macos-26 works.)

