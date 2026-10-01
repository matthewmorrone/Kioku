# Release & QA checklist

Pre-submission checklist for shipping a Kioku build to the App Store. Pair with
[APPSTORE.md](APPSTORE.md) (the metadata/submission kit) — this file is the
"is it ready?" gate; that file is "what to paste where."

## 1. Repo state
- [ ] On `main`, working tree clean (`git status`), latest pulled.
- [ ] CI green on the release commit: **invariants.yml** (automatic) and **tests.yml** (manual —
      run it from the Actions tab on the release commit) both passing.
- [ ] No open blockers in [todo.md](todo.md) that this release claims to fix.

## 2. Automated gates
- [ ] Segmentation eval (`scripts/segmentation-eval`: held2k, kana2k, lyrics, named cases) no
      worse than the last release if segmentation or the dictionary changed.
- [ ] Validate Invariants build phase passes (intent comments, file-size caps —
      see [INVARIANTS.md](INVARIANTS.md)); warnings acceptable, failures not.
- [ ] No new `print()` regressions / debug toggles exposed in release config
      (debug section is gated out of release builds).

## 3. Version & build
- [ ] Marketing version: pass `--version X.Y` to `scripts/distribute.sh` if user-facing changes.
- [ ] Build number: `scripts/distribute.sh` bumps it, commits the bump, and tags `vX.Y-N`
      after a successful upload.
- [ ] Deployment target still iOS 18.0 (the lyric-translation feature sits at the floor).

## 4. Manual QA smoke — core user loop
Run on a device (or simulator) before archiving. Until the automated UI smoke
tests land (todo: "UI automation tests for the core loop"), this is done by hand.
- [ ] **Notes**: create a note, paste Japanese text, segmentation renders with furigana.
- [ ] **Lookup/save**: tap a word → lookup sheet shows reading/lemma/inflected-form label;
      star it → appears in Words ▸ Saved with the glow in Read view.
- [ ] **Dictionary search**: query resolves; Words filters work (History/Saved, review status,
      JLPT level, note, list, sort, Show Kanji).
- [ ] **Kanji detail**: readings (on'yomi in hiragana), components section, common words,
      stroke-order animation, handwriting + radical input.
- [ ] **Study**: flashcards, multiple-choice, cloze, kana chart — each starts and grades.
- [ ] **Audio/karaoke** (if a song note exists): playback, active-cue highlight, ♪ interlude.
- [ ] **CSV import**: import a small list; "Fill kanji from dictionary" toggle behaves.
- [ ] **Backup**: export a backup, then restore it (with the pre-import confirmation) — no data loss.
- [ ] **Settings**: theme switch (System/Washi/Sumi), typography sliders, clipboard toggle.
- [ ] Cold launch: no crash, no visible first-frame jank on the Read tab.

## 5. Build, archive, upload
- [ ] `ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/distribute.sh [--version X.Y]` from a clean `main`:
      preflight (branch, clean tree, dictionary pin, invariants) → archive → export → upload → tag.
      `--no-upload` stops after exporting the .ipa to check signing. Prerequisites are in the
      script header. Fallback: Xcode → Product → Archive → Distribute App.
- [ ] Screenshots current (6.9", 1320 × 2868) — no personal notes visible.

## 6. TestFlight
- [ ] TestFlight smoke test on an **iOS 18.x** device if available — automated
      testing ran on the iOS 26.5 simulator; 18.0 is the deployment floor.
- [ ] Verify first-run downloads complete: the dictionary and the HuBERT phoneme aligner (GitHub
      releases), and the HTDemucs vocal isolator (Hugging Face) when a song is first aligned.

## 7. Submit
- [ ] Paste metadata from APPSTORE.md (description, keywords, privacy/age/export answers, review notes).
- [ ] Submit for review.

## 8. Post-release
- [ ] Confirm `scripts/distribute.sh` pushed the `vX.Y-N` tag.
- [ ] Note the shipped commit + build number in the handoff / `.remember`.
- [ ] Watch for crash reports / review feedback in the first day.
