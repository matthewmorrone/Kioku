# Todo

Open Kioku work only. Finished items are deleted, not ticked; git history has them. Each entry is
written so a new session can pick it up cold.

## Segmentation known cases
- [ ] **あめ|だ|の|せんべい should be あめ|だの|せんべい** (sample note キャラメルと飴玉). だの (and やら)
      have no rank in the frequency list (surface_readings best_rank 9999999), so they price as rare
      words: だ+の costs 4056 vs だの 4472 centi-nats (`segcli explain`). Scoring unranked particles
      by wordfreq zipf (だの 4.09) recovers ~390 of the 416 gap, not all; needs scoring work plus a
      full eval (held2k, kana2k, named cases, lyrics).

## Features
- [ ] Quiz on next and previous words/lines: points for consecutivity 
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
- [ ] **ポケベルならしてよんで segments as ポケベル|なら|して|よ|んで** — the one miss in the
      segmentation-eval lyric set (37/38; want ならして|よんで, 鳴らして 呼んで). `segcli explain`
      2026-09-27: wanted path loses by 300 centi-nats (7444 vs 7144), all of it in ならして — the
      noun → v5:て transition (ポケベル → ならして, 274) prices the dropped を (ポケベル[を]鳴らして)
      as unlikely, so なら|して ("if it's…, do") wins; よんで vs よ|んで is a tie (1543 vs 1544).
      The only lever found is a global one (transition weight/table fitted on held2k), expected to
      cost more than one lyric line — unmeasured. If picked up: `segcli fit` sweep of `WEIGHT CLAMP`
      on held2k + kana2k + lyrics before any change; a note-level merge fixes the song meanwhile.
- [ ] **`DictionaryTrie.Node.children` is `[Character: Node]` — consider a scalar-keyed
      dictionary instead.** Investigated 2026-07-13 while chasing cold-start latency
      (`StartupTimer` measured `trie population (456249 records)` at ~1005ms). `Character` is a
      variable-width grapheme-cluster type; hashing/equality has to account for Unicode
      grapheme-boundary edge cases that essentially never apply to dictionary/user text (kanji/
      kana are almost always single Unicode scalars). Switching `children` to a scalar key
      (e.g. `[UInt32: Node]` keyed by `Unicode.Scalar.value`) would speed up not just the
      one-time trie build but every lookup during live segmentation too (`contains`,
      `partOfSpeech`, `hitMeta`, `prefixScan`, `prefixHitScan` — all contained to `Kioku/Dictionary/DictionaryTrie.swift` +
      `Kioku/Dictionary/Node.swift`, nothing else touches `.children`). Estimated payoff is
      modest and uncertain without benchmarking — maybe 200-400ms off the trie-build step,
      nothing for `fetchSurfaceData` (a separate function; its query plan already uses
      `idx_kanji_text`/`idx_kana_text` reasonably well).
      Correctness risk: multi-scalar Characters (rare combining-mark sequences) would need
      either an NFC-normalization safety net before scalar iteration, or accepting the
      near-zero real-world risk that Japanese dictionary/user text is already NFC-precomposed.
      Not started; on hold until the user says go (2026-09-26). Measure cold start with
      `StartupTimer` before and after.
- [ ] **Unknown katakana runs: option A vs B — the user hasn't chosen (2026-10-03).** B is
      shipped (`68754dba`): a whole-run edge for unknown katakana, and hiragana-only pieces inside a
      katakana run pay a penalty. It fixes ミンツ and keeps 11 held2k names whole, with no change to
      held2k cut-throughs (79) or named cases (62/63). A drops those pieces outright: it also
      fixes カステイラ and ウエファース and keeps 18 names whole, but held2k goes to 81
      cut-throughs and the named case ナカナイ|ヨ breaks (katakana-for-effect speech becomes one
      blob). Choosing A means updating that named case, which is a test change: ask first.
      Possible C: A, but keep the pieces when every piece is a hiragana-read word (ミンツ slips
      through). The uncertainty item below may make the choice unnecessary.
- [ ] **Fuzzy katakana lookup, labelled as a guess** — approved 2026-10-02, not built. Old
      loanword spellings (カステイラ for カステラ, ウエファース for ウエハース) miss JMdict. At lookup
      time, try regular katakana variants (ファ↔ハ, ティ↔チ, a dropped or extra イ/ー) and show a
      hit marked "· guess", like the AI gloss guess. Never feeds segmentation.
- [ ] **Segment uncertainty, then AI correction of only the low-confidence spans** — planned
      2026-10-02. The segmenter's costs are centi-nats, so: (1) forward–backward over the existing
      lattice gives each segment a probability summed over all paths; (2) fit one temperature on
      held2k so "0.8" means right 80% of the time; (3) send only spans below a threshold to the AI
      correction model, instead of whole lines. Read-only alongside the current path search, so no
      segmentation change. Targets waiting on it, all near-ties in the キャラメルと飴玉 sample
      (ours vs wanted, centi-nats): あめ|だ|の 6453 vs だの 6869; お|菓子箱 8397 vs お菓子|箱 8694;
      おしまい|なさい 4373 vs お|しまい|なさい 5338; ドロップ|ス 4248 vs ドロップス 5673. Also
      the reading choices of the same kind: 態 in 態をみろ reads たい (should be ざま), 方
      ほう/かた, 中 なか/ちゅう, 分 ふん/ぶん. Don't retry "prefer the reading that spells a
      dictionary word with the following kana": measured 2026-10-02 at 87.38% → 86.04% on
      `score_readings.py`, fixed nothing, broke 18 (short kana strings always spell some word).

## Testing
- [ ] **UI automation tests for the core loop** (notes, lookup/save, study, backup). Store-level
      coverage exists (`CoreLoopSmokeTests`, `AppBackupValidatorTests`); nothing drives the actual UI.
      The `KiokuUITests` target already exists in the project with no source files (the template
      tests were removed in `372c42a`), so this means adding a `KiokuUITests/` folder with XCUITests.
      They run on the phone or in CI; this Mac has no simulator runtime.

