# Infrastructure Backlog

Single source of truth for **infrastructure, testing, and tooling work** carried over from prior sessions. The product backlog lives in [todo.md](todo.md) — this file is the technical side: tests to write, bugs to verify, follow-ups on the CI / invariant / store-test work.

Items are roughly ordered by suggested priority. Each entry is written so a new session can pick it up cold — no context from the originating conversation required.

---

## Reading-specific dictionary issues

Surface segments correctly but display the wrong reading. Each needs a probe through `surfaceReadingData` / dictionary lookup to confirm whether it's still broken post the recent kana-form-ordering and lemma-scoring fixes. If still broken, the fix path goes through `DictionaryStore+SurfaceData.swift` or the kana-form-ranking logic. If resolved, fold into `SegmentationKnownGoodTests` (or a sibling characterization test) and remove from [test-failures.md](test-failures.md).

- [ ] **消してくれる** — was showing reading しゅう instead of けして (from 消す). Lemma now resolves to 消す; reading needs re-verification.
- [ ] **抱かれ** — was missing readings いだかれ / だかれ / うだかれ. Lemma resolves to 抱く; reading set needs re-verification.
- [ ] **月色** — should have reading つきいろ. Lemma resolves to 月色; reading needs re-verification.

Estimated effort: ~15 min triage script that probes `surfaceReadingData` for each, then per-case fix if broken.

---

## Still-broken segmentation cases

These segments don't resolve to a full-span lattice edge. Each requires either a deinflection rule addition (in `Resources/deinflection.json`) or a lexicon entry (in `Resources/extras.json`). When fixed, port to `SegmentationKnownGoodTests`.

- [ ] **済まれないで** — not recognized. Likely needs a deinflection rule for the passive + negative + で linking chain on 済む.
- [ ] **ショーブかけましょ** — full string not segmented as one word; mixed-script loanword + native verb compound. The ー expansion fix from earlier didn't reach this case.
- [ ] **ちゃいのん** — not recognized. Possibly dialectal / casual; may need an `extras.json` entry, or it may be intentional to leave unrecognized.

Estimated effort: per-case investigation + a rule or extras.json line + a test. ~20 min each.

---

## Store-level test coverage

Seven persistence stores still lack matching `*Tests.swift` files. Invariant 8 fires a warning for each on every commit / push / CI run, so the gap stays visible. Pattern established in [HistoryStoreTests.swift](../KiokuTests/HistoryStoreTests.swift) (UserDefaults-backed) and [NotesStoreTests.swift](../KiokuTests/NotesStoreTests.swift) (file-backed via injectable `TestFileManager`).

Ordered by likely impact:

- [x] **WordsStore** — saved-word lifecycle; data-loss risk if broken. Done 2026-05-25: 29 tests in `WordsStoreTests.swift`, covering CRUD, list membership, selections, move, reload, and the rich `toggle(...)` semantics (note attribution, encountered-surfaces set, card-removal-only-when-both-empty). One latent bug fixed: `SavedWordStorage.normalizedEntries` was re-constructing the merged `SavedWord` without passing `encounteredSurfaces`, which the init defaults to `Set([surface])` — so every encountered form from both inputs was silently discarded. No production path currently feeds duplicates through normalize (toggle/replaceAll callers produce unique IDs), but the helper's contract is "coalesce duplicates without data loss" and any new caller (CSV import, hand-edited backup, future bulk add) would hit it. Pinned by `testNormalizedEntriesMergesEncounteredSurfacesFromDuplicates`. Pattern note: `SavedWordStorage` already took `userDefaults: UserDefaults = .standard`; the change was to thread that through `WordsStore.init` and the `persist`/`reload` callers. Tests inject `UserDefaults(suiteName: "kioku-words-tests-\(UUID().uuidString)")` and clean it up in tearDown.
- [x] **SavedWordStorage** — disk format for saved words. Implicitly covered by the WordsStoreTests above (the suite tests `normalizedEntries` directly, plus exercises every disk-roundtrip path through WordsStore as a host). The store-test invariant in `validate_invariants.sh` will still flag this file as untested because the matcher looks for a `SavedWordStorageTests.swift` filename specifically — worth either adding a one-line stub that delegates, updating the matcher to accept "covered by sibling", or accepting the warning as known-suppressed.
- [ ] **WordListsStore** — list membership / dedup. (~66 LOC)
- [x] **NotesAudioStore** — audio attachment metadata for notes. Done 2026-05-24: 19 tests in `NotesAudioStoreTests.swift`. Two bugs surfaced and fixed in the same change: (a) `importAttachment` was passing `audioFilename` ("song.mp3") as `saveSRT`'s `preferredFilename`, which made the SRT inherit the audio extension and overwrite the audio bytes; fixed by routing through `preferredSubtitleFilename(forAudioFilename:)`. (b) `readableFilename` split the storage stem on the first hyphen to reverse `{uuid}-{base}`, but UUIDs themselves contain 4 internal hyphens, so the function returned a UUID-tainted string for any preserved-basename file — silently broke `audioBaseName`-driven TextGrid sibling matching in `BulkImportPlanner`; fixed by detecting the UUID prefix as fixed-width (36 chars) + validity.
- [ ] **SongBreakdownStore** — persisted LLM breakdowns; round-trip + recovery already partially covered by `SongBreakdownRecoveryTests`.
- [ ] **ReviewStore** — flashcard review metrics.
- [ ] **DictionaryStore** — read-only by nature; lowest risk. Direct lookups already exercised by many integration tests. Could be considered "implicitly tested" if you want to retire the warning.

Estimated effort: 30–60 min per store using the established pattern.

### Pattern note for the remaining stores

`NotesAudioStore` followed `NotesStore`'s injection pattern adapted for a singleton: keep `static let shared` for production wiring, add a non-private designated `init(audioDirectory: URL)` so tests scope to a per-case temp dir. When the production code is already pure-singleton (`static let shared = ...; private init()`), the minimal change is to (a) extract the production base URL into a `private static func defaultXxx()` helper, (b) make the init public/internal, take the base URL as a parameter, and (c) have `.shared` call the new init with the default. Tests then construct fresh instances against `FileManager.default.temporaryDirectory.appendingPathComponent("kioku-…-tests-\(UUID().uuidString)")` and tear down the dir in `tearDown`.

---

## CI / tooling watch list

Things that aren't broken but could become so. Not actionable today — just worth a periodic look.

- [ ] **`macos-26` is a GitHub Actions preview runner.** If GH deprecates the preview image before iOS 26.5 reaches `macos-15`, CI breaks until we react. Fallback path: `xcrun simctl runtime install` to add iOS 26.5 to `macos-15`, or accept skip-testing the affected suites.
- [ ] **Coverage step-summary parsing.** The Python jq pipeline in `tests.yml` reads `coveredLines` and `executableLines` from `xccov view --report --json`. If Xcode changes the xcresult JSON shape, the summary silently emits nothing (the `if [[ ! -d ... ]]` guard would not catch it). Worth verifying after each Xcode major.
- [ ] **Submodule SSH-to-HTTPS rewrite assumes the SwiftWhisper fork stays public.** If it's ever flipped to private, CI breaks; either provision a deploy key or pin to a fork URL that stays accessible.

---

## Verified clean (no follow-up needed)

For reference — these were checked during the recent infra pass and have no remaining work:

- ✅ Zero `// TODO` / `// FIXME` / `// XXX` / `// HACK` / `// TBD` comments anywhere in `Kioku/`, `KiokuTests/`, or `SwiftWhisperAlign/`. (Last verified 2026-05-24.)
- ✅ No vestigial root-level config (`package.json` / `node_modules` cleared).
- ✅ `AGENTS.md` aligned with current invariants (file-size, store-test, setup.sh).

## Watch list — degrading since last triage (2026-05-24)

- ⚠️  **`print()` call count rose 72 → 101.** Top new offenders: `ReadView+LLMCorrection.swift` (14), `OnDeviceLyricAligner.swift` (13), `WhisperModelManager.swift` (10). Worth a pass to route through `os.Logger` (subsystem-tagged so they're filterable in Console.app) rather than `print`, especially in the LLM/alignment paths where the calls describe real failure modes that would benefit from being structured.
- ⚠️  **Largest file crossed the 800-line warning threshold.** `SwiftWhisperAlign/Sources/SwiftWhisperAlign/ForcedAlignmentProvider.swift` is now 814 LOC (was 766). Split candidates: provider façade ↔ alignment math ↔ transcription fallback. Other ≥700-line files now: `SubtitleEditorSheet.swift` 758, `ReadView+LLMCorrection.swift` 741, `ReadView+Segmentation.swift` 735, `ReadView+AudioTranscription.swift` 718.
- ⚠️  **`ReadView` extension sprawl.** 19 `ReadView+*.swift` files totaling 6,427 LOC all share the same `View`'s `@State` — extensions split text, not state ownership, so any new feature touches multiple files and any state rename is a 19-file change. Phase-3 architectural item; tracked as the one structural debt that will keep compounding if deferred. Brainstorm before starting: extract `@StateObject ReadViewModel`, or carve out subsystem-owned view models (`SegmentationViewModel`, `LookupViewModel`, `LyricsViewModel`, `LLMCorrectionViewModel`) matching the existing folder split.
- ⚠️  **`SWIFT_VERSION = 5.0` while `IPHONEOS_DEPLOYMENT_TARGET = 26.2`.** Modern OS minimum, legacy language mode — Swift 6 strict-concurrency hardening (a real bug class given the async transcription/alignment surface) is off the table until bumped. Worth doing once while the codebase is small enough to audit the fallout in one PR.
- ⚠️  **35 force unwraps (`!`) in non-production-test Swift.** Low absolute count but each is a latent crash; no audit log exists. One-pass triage: label each as either covered by an invariant elsewhere (leave with a one-line `// invariant: …` comment) or latent crash (fix).
