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

- [ ] **WordsStore** — saved-word lifecycle; data-loss risk if broken. (~141 LOC)
- [ ] **SavedWordStorage** — disk format for saved words. (~75 LOC)
- [ ] **WordListsStore** — list membership / dedup. (~66 LOC)
- [ ] **NotesAudioStore** — audio attachment metadata for notes.
- [ ] **SongBreakdownStore** — persisted LLM breakdowns; round-trip + recovery already partially covered by `SongBreakdownRecoveryTests`.
- [ ] **ReviewStore** — flashcard review metrics.
- [ ] **DictionaryStore** — read-only by nature; lowest risk. Direct lookups already exercised by many integration tests. Could be considered "implicitly tested" if you want to retire the warning.

Estimated effort: 30–60 min per store using the established pattern.

---

## CI / tooling watch list

Things that aren't broken but could become so. Not actionable today — just worth a periodic look.

- [ ] **`macos-26` is a GitHub Actions preview runner.** If GH deprecates the preview image before iOS 26.5 reaches `macos-15`, CI breaks until we react. Fallback path: `xcrun simctl runtime install` to add iOS 26.5 to `macos-15`, or accept skip-testing the affected suites.
- [ ] **Coverage step-summary parsing.** The Python jq pipeline in `tests.yml` reads `coveredLines` and `executableLines` from `xccov view --report --json`. If Xcode changes the xcresult JSON shape, the summary silently emits nothing (the `if [[ ! -d ... ]]` guard would not catch it). Worth verifying after each Xcode major.
- [ ] **Submodule SSH-to-HTTPS rewrite assumes the SwiftWhisper fork stays public.** If it's ever flipped to private, CI breaks; either provision a deploy key or pin to a fork URL that stays accessible.

---

## Verified clean (no follow-up needed)

For reference — these were checked during the recent infra pass and have no remaining work:

- ✅ Zero `// TODO` / `// FIXME` / `// XXX` / `// HACK` comments anywhere in `Kioku/`.
- ✅ 72 `print()` calls reviewed; all are legitimate error logging or instrumentation (`TapDiagnostics`, `NotesStore` defensive-guard warnings).
- ✅ Largest source file is 766 LOC, well under the 800-line warning threshold and 1000-line fail threshold.
- ✅ No vestigial root-level config (`package.json` / `node_modules` cleared).
- ✅ `AGENTS.md` aligned with current invariants (file-size, store-test, setup.sh).
