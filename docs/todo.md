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

These segments don't resolve to a full-span lattice edge. Each requires either a
deinflection rule addition (in `Resources/deinflection.json`) or a lexicon entry
(in `Resources/extras.json`). When fixed, port to `SegmentationKnownGoodTests`.

- [ ] **済まれないで** — not recognized. Likely needs a deinflection rule for the passive + negative + で linking chain on 済む.
- [ ] **ショーブかけましょ** — full string not segmented as one word; mixed-script loanword + native verb compound. The ー expansion fix from earlier didn't reach this case.
- [ ] **ちゃいのん** — not recognized. Possibly dialectal / casual; may need an `extras.json` entry, or it may be intentional to leave unrecognized.

Estimated effort: per-case investigation + a rule or extras.json line + a test. ~20 min each.

## Read View

- [ ] Note-level TTS: play/pause, rate and voice controls, spoken-range highlighting
      (basic `AVSpeechSynthesizer` speak exists in `SurfaceSheetViewController+Build.swift` —
      missing controls and highlight)
- [ ] Quiz on next and previous words/lines

## Words & Dictionary

- [x] Add personal note to saved words
- [x] CSV import: flexible parsing (`CSVImport.swift` `parseItems()` handles varied column layouts)
- [x] List conjugations in dictionary view (`WordDetailView.swift:33-34` + `ConjugationSheetView.swift`)
- [x] Variants section in WordDetail: list all kanji and kana forms of the entry, labeled, separate from the saved surface (`WordDetailView.swift:4`)
- [ ] Add manual/custom word creation and editing
- [ ] Deduplicate example sentences
- [ ] Custom reading popup should be prefilled and set to Japanese keyboard
      (UI exists; missing `.keyboardType` JP IME hint)
- [ ] Make saving to the words list more responsive
- [ ] Add advanced dictionary filters/sorting (JLPT, POS, frequency, commonness toggles)
- [ ] Romaji display option (romaji→kana *search* shipped; *display* toggle not implemented)
- [ ] alternateSpellings(): include kanji variants (currently kana-only at `WordDetailView.swift:483-494`, and only when the saved surface contains kanji)
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
- [ ] Clipboard behavior settings (auto-lookup is on; no user toggle)

## Ship Readiness

- [x] Hide/gate debug section and diagnostic toggles from release builds
- [x] Add explicit pre-import confirmation for backup restore
- [x] Progressive disclosure in dictionary detail UI (`DisclosureGroup` in `WordsView+Search.swift`, `SongLineCard.swift`)
- [ ] Add UI smoke tests for core user loop (notes, lookup/save, study, backup)
- [ ] Split Settings into Basic vs Advanced (move advanced controls behind secondary screen)
- [ ] Accessibility pass (62× `.accessibilityLabel` present; missing Dynamic Type / `scaledMetric` sizing and contrast audit)
- [ ] App Store packaging artifacts and release QA checklist
- [ ] Credits/About screen with dataset attributions (JMdict, Tatoeba, IPADic, fastText)

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
- [ ] **WordListsStore** — list membership / dedup. (~66 LOC)
- [ ] **SongBreakdownStore** — persisted LLM breakdowns; round-trip + recovery already partially covered by `SongBreakdownRecoveryTests`.
- [ ] **ReviewStore** — flashcard review metrics.
- [ ] **DictionaryStore** — read-only by nature; lowest risk. Direct lookups already exercised by many integration tests. Could be considered "implicitly tested" if you want to retire the warning.

Estimated effort: 30–60 min per store using the established pattern.

### Pattern note for the remaining stores

`NotesAudioStore` followed `NotesStore`'s injection pattern adapted for a singleton: keep `static let shared` for production wiring, add a non-private designated `init(audioDirectory: URL)` so tests scope to a per-case temp dir. When the production code is already pure-singleton (`static let shared = ...; private init()`), the minimal change is to (a) extract the production base URL into a `private static func defaultXxx()` helper, (b) make the init public/internal, take the base URL as a parameter, and (c) have `.shared` call the new init with the default. Tests then construct fresh instances against `FileManager.default.temporaryDirectory.appendingPathComponent("kioku-…-tests-\(UUID().uuidString)")` and tear down the dir in `tearDown`.

## CI / tooling watch list

Things that aren't broken but could become so. Not actionable today — just worth a periodic look.

- [ ] **`macos-26` is a GitHub Actions preview runner.** If GH deprecates the preview image before iOS 26.5 reaches `macos-15`, CI breaks until we react. Fallback path: `xcrun simctl runtime install` to add iOS 26.5 to `macos-15`, or accept skip-testing the affected suites.
- [ ] **Coverage step-summary parsing.** The Python jq pipeline in `tests.yml` reads `coveredLines` and `executableLines` from `xccov view --report --json`. If Xcode changes the xcresult JSON shape, the summary silently emits nothing (the `if [[ ! -d ... ]]` guard would not catch it). Worth verifying after each Xcode major.
- [ ] **Submodule SSH-to-HTTPS rewrite assumes the SwiftWhisper fork stays public.** If it's ever flipped to private, CI breaks; either provision a deploy key or pin to a fork URL that stays accessible.

## Watch list — degrading since last triage (2026-05-24)

- ⚠️  **`print()` call count rose 72 → 101.** Top new offenders: `ReadView+LLMCorrection.swift` (14), `OnDeviceLyricAligner.swift` (13), `WhisperModelManager.swift` (10). Worth a pass to route through `os.Logger` (subsystem-tagged so they're filterable in Console.app) rather than `print`, especially in the LLM/alignment paths where the calls describe real failure modes that would benefit from being structured.
- ⚠️  **Largest file crossed the 800-line warning threshold.** `SwiftWhisperAlign/Sources/SwiftWhisperAlign/ForcedAlignmentProvider.swift` is now 814 LOC (was 766). Split candidates: provider façade ↔ alignment math ↔ transcription fallback. Other ≥700-line files now: `SubtitleEditorSheet.swift` 758, `ReadView+LLMCorrection.swift` 741, `ReadView+Segmentation.swift` 735, `ReadView+AudioTranscription.swift` 718.
- ⚠️  **`ReadView` extension sprawl.** 19 `ReadView+*.swift` files totaling 6,427 LOC all share the same `View`'s `@State` — extensions split text, not state ownership, so any new feature touches multiple files and any state rename is a 19-file change. Phase-3 architectural item; tracked as the one structural debt that will keep compounding if deferred. Brainstorm before starting: extract `@StateObject ReadViewModel`, or carve out subsystem-owned view models (`SegmentationViewModel`, `LookupViewModel`, `LyricsViewModel`, `LLMCorrectionViewModel`) matching the existing folder split.
- ⚠️  **`SWIFT_VERSION = 5.0` while `IPHONEOS_DEPLOYMENT_TARGET = 26.2`.** Modern OS minimum, legacy language mode — Swift 6 strict-concurrency hardening (a real bug class given the async transcription/alignment surface) is off the table until bumped. Worth doing once while the codebase is small enough to audit the fallout in one PR.
- ⚠️  **35 force unwraps (`!`) in non-production-test Swift.** Low absolute count but each is a latent crash; no audit log exists. One-pass triage: label each as either covered by an invariant elsewhere (leave with a one-line `// invariant: …` comment) or latent crash (fix).

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
- ✅ **抱かれ** — readings いだかれ / だかれ / うだかれ pinned by `testIdakare()` in `SegmentationKnownGoodTests.swift:57-68`
- ✅ **月色** — reading つきいろ pinned by `testTsukiiro()` in `SegmentationKnownGoodTests.swift:57-68`

## Segmentation cases (now pinned)

- ✅ つないだ → one segment, lemma つなぐ
- ✅ まけない → one segment, lemma まける
- ✅ その度 → one segment, lemma その度
- ✅ トキメク → one segment, lemma ときめく (katakana → kana iteration via expansion)
- ✅ しょげちゃうんだ → one segment, lemma しょげる
- ✅ かなえて → one segment, lemma かなえる
- ✅ プレイヤーズ → one segment, recognized via extras.json
- ✅ ティアーズ → one segment, recognized via extras.json
