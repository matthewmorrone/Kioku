# Release & QA checklist

Pre-submission checklist for shipping a Kioku build to the App Store. Pair with
[APPSTORE.md](APPSTORE.md) (the metadata/submission kit) — this file is the
"is it ready?" gate; that file is "what to paste where."

## 1. Repo state
- [ ] On `main`, working tree clean (`git status`), latest pulled.
- [ ] CI green on the release commit: **tests.yml** and **invariants.yml** both passing.
- [ ] No `[~]`/`[ ]` blockers in [todo.md](todo.md) that this release claims to fix.

## 2. Automated gates (must pass locally too)
- [ ] `xcodebuild test` (Kioku scheme) — full unit suite green.
- [ ] Validate Invariants build phase passes (intent comments, file-size caps —
      see [INVARIANTS.md](INVARIANTS.md)); warnings acceptable, failures not.
- [ ] No new `print()` regressions / debug toggles exposed in release config
      (debug section is gated out of release builds).

## 3. Version & build
- [ ] Bump marketing version (CFBundleShortVersionString) if user-facing changes.
- [ ] Bump build number (CFBundleVersion) — must exceed the last uploaded build.
- [ ] Deployment target still iOS 18.0 (the lyric-translation feature sits at the floor).

## 4. Manual QA smoke — core user loop
Run on a device (or simulator) before archiving. Until the automated UI smoke
tests land (todo: "UI smoke tests for core user loop"), this is done by hand.
- [ ] **Notes**: create a note, paste Japanese text, segmentation renders with furigana.
- [ ] **Lookup/save**: tap a word → lookup sheet shows reading/lemma/inflected-form label;
      star it → appears in Words ▸ Favorites with the glow in Read view.
- [ ] **Dictionary search**: query resolves; filters work (JLPT, POS, Common Only,
      frequency tier); kanji-content filter (All / Kanji Only / No Kanji).
- [ ] **Kanji detail**: readings (on'yomi in hiragana), components section, common words,
      stroke-order animation, handwriting + radical input.
- [ ] **Study**: flashcards, multiple-choice, cloze, kana chart — each starts and grades.
- [ ] **Audio/karaoke** (if a song note exists): playback, active-cue highlight, ♪ interlude.
- [ ] **CSV import**: import a small list; "Fill kanji from dictionary" toggle behaves.
- [ ] **Backup**: export a backup, then restore it (with the pre-import confirmation) — no data loss.
- [ ] **Settings**: theme switch (System/Washi/Sumi), typography sliders, clipboard toggle.
- [ ] Cold launch: no crash, no visible first-frame jank on the Read tab.

## 5. Build, archive, upload
- [ ] Xcode → Product → Archive → Distribute App → App Store Connect
      (Distribution cert minted automatically). See APPSTORE.md §"Steps only you can do".
- [ ] Screenshots current (6.9", 1320 × 2868) — no personal notes visible.

## 6. TestFlight
- [ ] TestFlight smoke test on an **iOS 18.x** device if available — automated
      testing ran on the iOS 26.5 simulator; 18.0 is the deployment floor.
- [ ] Verify on-device model assets download/decompress on first run (handwriting model, etc.).

## 7. Submit
- [ ] Paste metadata from APPSTORE.md (description, keywords, privacy/age/export answers, review notes).
- [ ] Submit for review.

## 8. Post-release
- [ ] Tag the release commit (`git tag vX.Y.Z && git push --tags`).
- [ ] Note the shipped commit + build number in the handoff / `.remember`.
- [ ] Watch for crash reports / review feedback in the first day.
