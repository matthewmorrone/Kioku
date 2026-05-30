# Todo

Single source of truth for Kioku product, infrastructure, and triage work.
Each entry is written so a new session can pick it up cold — no prior conversation
required.

Last consolidated: 2026-05-25 (merged `infra-backlog.md` and `test-failures.md` here).

---

## Bugs

- [ ] Ruby persistent overhang spacing on the left edge
- [ ] Distribute spacing better for multikanji ruby headwords
- [x] Combining or splitting words: save button state not refreshed after merge/split
- [ ] Clicking the star button doesn't always trigger bookmarking (bookmark button works)
- [ ] Typing freely in English in the paste area is super laggy

## Segmentation & Lookup

- [x] Halfwidth katakana normalization in lookup (ｱｲｳｴｵ → アイウエオ)
- [x] Lexicon lemma ranking respects saved-word surfaces when scoring inflection candidates (`Lexicon.swift:241-270` — `resolve()` ranks lexemes by saved surface + inflection-chain score)
- [ ] Use frequency data to influence segmentation path selection
- [ ] Provide meaning of verbs in the form they surface in

### Still-broken segmentation cases

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

- [ ] Note-level TTS: play/pause, rate and voice controls, spoken-range highlighting
      (basic `AVSpeechSynthesizer` speak exists in `SurfaceSheetViewController+Build.swift` —
      missing controls and highlight)
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
- [ ] Custom reading popup should default to Japanese keyboard — blocked by `UIAlertController.addTextField(configurationHandler:)`: it hands you a UIKit-managed `UITextField` whose class you can't change, and UIKit has no public "prefer Japanese input mode" API short of overriding `textInputMode` on a `UITextField` subclass. Clean fix: replace the alert with a custom modal hosting a `JapaneseTextField` that overrides `textInputMode` to prefer `UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("ja") == true }`.
- [x] Make saving to the words list more responsive — shipped via `WordsStore.persistQueue` (serial utility-QoS DispatchQueue) so star-toggles return immediately and persist off-main; lemma-cache + off-main hydration on `SegmentLookupSheet` load eliminates the redundant SQL pass that was making first-tap latency visible. `WordsStore.flushPendingWritesForTesting()` provides the sync surface for tests.
- [ ] Add advanced dictionary filters/sorting (JLPT, POS, frequency, commonness toggles)
- [ ] Romaji display option (romaji→kana *search* shipped; *display* toggle not implemented)
- [x] alternateSpellings(): include kanji variants — extracted from `WordDetailView` to `Kioku/Words/WordVariants.swift` so it's unit-testable; now surfaces both kanji-form and kana-form alternates (was kana-only), filters out `oK`/`sK`/`ok`/`sk` archaic + search-only forms, keeps irregular (`iK`/`ik`) variants. Pinned by `WordVariantsTests.swift` (6 tests). The previous `count > 1` noise-suppression gate is dropped — for kanji-bearing surfaces, even a single alternate is informative now that kanji variants are included. Pure-kana saved surfaces still return [] (false-uniqueness guard preserved).
- [ ] CSV import: explicit option to fill kanji from the dictionary when the surface column is missing (today the importer silently substitutes kanji even when only kana was provided)

## Study & Review

- [x] Spaced repetition scheduling — basic streak-based SRS shipped (`SRSScheduler.swift` + `ReviewWordStats.swift`: due dates, `consecutiveCorrect`, interval ladder). FSRS-style ease-factor algorithm is a possible future upgrade, not yet implemented.
- [x] Auto clipboard paste/search (`ClipboardLookupCoordinator.swift`, wired in `ContentView.swift`)

## Kanji

- [x] Dedicated kanji discovery tab/screen (`RadicalInputView()` sheet in `WordsView.swift`, "Find kanji by radical" toolbar button)
- [ ] Full kanji metadata support (radicals, readings, components)
      (partial: `KanjiInfo` has radicals + stroke count; component tree not confirmed)
- [ ] Handwriting input and stroke order (radical input shipped; handwriting recognition still TBD)
- [ ] Kanji of the day feature

## Audio & Alignment

- [x] Expand karaoke alignment benchmark dataset and add CI evaluation job
      (`AlignmentQualityTests.swift` runs in `tests.yml`; 16 SailorMoon songs aligned via stable-ts large-v3)
- [ ] Native human audio pronunciation dataset support (beyond TTS)
- [ ] Vocal-vs-instrumental detection via Apple's Sound Analysis framework
      (`SNClassifySoundRequest` with the built-in speech/music classifier). Tap audio via
      `AVAudioEngine`, feed frames to the classifier, surface an `isVocalActive` published
      property on `AudioPlaybackController`. Lyrics popup gates "in vocal cue" on this so
      cues with bad SRT/TextGrid timing show the pulsing ♪ until the vocal actually arrives.
      Self-correcting per-song, no manual data fixes required.
- [ ] Audio-level silence detection (lightweight complement to vocal detection above).
      Use the existing `AVAudioPlayer.averagePower` meter with a hysteresis-gated threshold
      (e.g., level < 0.15 for > 300ms) to detect true silence between/before tracks. Cheaper
      than Sound Analysis but only catches actual quiet, not "instrumental without vocal".
- [ ] Unified ResolvedCue data model: replace the parallel `cues: [SubtitleCue]` +
      `cueTimings: [Int: [CueCharTiming]]` pair with a single value type that owns SRT cue
      boundaries AND optional TextGrid character checkpoints, with consistency validation at
      load time (drop or shift stale checkpoints whose timestamps fall outside the SRT
      cue's [startMs, endMs]). Consumers (AudioCueHighlightObserver, LyricsView) query a
      single source instead of cross-referencing two. Solves the class of bugs where
      hand-editing the SRT leaves stale TextGrid timings driving the per-word band.
- [ ] Fix karaoke trace ~150-200ms lead (AVAudioSession I/O latency uncompensated)

## Settings

- [x] Adjust ruby typography settings (spacing, padding) — `SettingsView.swift:17` `furiganaGapKey` + sliders for `furiganaGap`, `kerning`, `lineSpacing`
- [ ] Default to Japanese IME where appropriate (no `TextField` keyboard-type hints found)
- [x] Clipboard behavior settings — `ClipboardSettings.swift` defines `autoDetectKey` + `defaultAutoDetect = true`; new "Clipboard" section in `SettingsView` toggles it. `ClipboardLookupCoordinator.checkClipboard()` short-circuits before any pasteboard read when off, so iOS's "Pasted from" notification doesn't fire for users who turn it off. Coordinator's `init(defaults:)` takes an injected `UserDefaults` so the gate is testable; pinned by 4 tests in `ClipboardLookupCoordinatorTests.swift`.

## Ship Readiness

- [x] Hide/gate debug section and diagnostic toggles from release builds
- [x] Add explicit pre-import confirmation for backup restore
- [x] Progressive disclosure in dictionary detail UI (`DisclosureGroup` in `WordsView+Search.swift`, `SongLineCard.swift`)
- [ ] Add UI smoke tests for core user loop (notes, lookup/save, study, backup)
- [ ] Split Settings into Basic vs Advanced (move advanced controls behind secondary screen)
- [ ] Accessibility pass (62× `.accessibilityLabel` present; missing Dynamic Type / `scaledMetric` sizing and contrast audit)
- [ ] App Store packaging artifacts and release QA checklist
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
