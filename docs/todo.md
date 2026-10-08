# Todo

Open Kioku work only. Finished items are deleted, not ticked; git history has them. Each entry is
written so a new session can pick it up cold.

## Segmentation known cases
## Features
- [ ] Quiz on next and previous words/lines: points for consecutivity 
- [ ] **Real-time kanji-choice game mode** — pick the correct kanji as fast as possible; score
      on speed + accuracy in near-real-time (from app-usage backlog 2026-07-01). Needs a design
      pass (grilling) before building: question source (saved words? by JLPT/frequency?), distractor
      selection, timer/scoring model, round length, how it ties into `ReviewStore` (does a fast
      correct answer count as a review?). Sits alongside the existing MultipleChoiceView.
## Segmentation & Lookup
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
      **2026-10-07/08 results.** Near-tie margin code parked on branch `claude/segment-near-ties`
      (Segmenter.nearTies via splitCosts, `segcli nearties`, `score_nearties.py`; keep the branch).
      margin<300 flags 1030 held2k windows and catches 35% of cut-throughs (kana2k 45%), but only ~30
      flagged windows are fixable errors vs ~900 correct; most gold "errors" are conventions (ん|だ vs
      んだ) — real misreadings in a 15-error sample: 3 (中|日間, どう|やらない, ので|あった). AI
      correction must be on-device Apple Intelligence (FoundationModels), never OpenAI (user
      decision). On-device A/B on 30 spans (15 Kioku-wrong, 15 right): bare cuts fixed 7/15, broke
      6/15, answered "A" 22/30; with dictionary meanings per piece fixed all 3 real misreadings but
      broke こんなに, 実は, 英日間; with POS + meanings + translate-first + agreement across both
      option orders it picked A 28/30 in both orders (position bias): 0 fixes, 1 convention change.
      The on-device model can't judge segmentation — don't retry without a materially stronger
      model. Left open; the user wants to come back to it.

## Testing
- [ ] **UI automation tests for the core loop** (notes, lookup/save, study, backup). Store-level
      coverage exists (`CoreLoopSmokeTests`, `AppBackupValidatorTests`); nothing drives the actual UI.
      The `KiokuUITests` target already exists in the project with no source files (the template
      tests were removed in `372c42a`), so this means adding a `KiokuUITests/` folder with XCUITests.
      They run on the phone or in CI; this Mac has no simulator runtime.

