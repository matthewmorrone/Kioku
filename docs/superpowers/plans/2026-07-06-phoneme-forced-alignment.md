# Lyric alignment: measured path to better placement (phoneme / global forced align)

Date: 2026-07-06
Status: plan (not started). Supersedes the ad-hoc anchor-gate edits, which were reverted.

## Why this exists

Repeated on-device debugging of 月色チャイのん (`tsukiiro-chainon`) chased a mis-timed line
(悲しみの嘘を忘れない showing ~2:59, before the ♪). Several blind edits to the shared aligner
followed; one regressed ordering across the song and was reverted (commit `revert(align): back out
the ambiguity-gated anchor change`). Root lesson: **do not change the aligner without grading it.**

## Ground truth (from the repo oracle, authoritative)

`KiokuTests/Fixtures/alignment/tsukiiro-chainon.ground-truth.srt` (stable-ts large-v3) shows the
phrase at TWO times, in two distinct note lines:

- note line 8  `悲しみの嘘を忘れないその物語オーロール`  → **0:59.260**
- note line 27 `悲しみの嘘を忘れない`                  → **3:29.040**

So the lyric **repeats**. The earlier "it's a unique line the chorus gate wrongly dropped"
hypothesis was FALSE. The real failure is **repeated-lyric disambiguation** in the anchor-and-fill
stage: the aligner windows the audio by mined anchors (it can't hold the whole song in one CTC
pass), and a repeated phrase's anchor can attach to the wrong occurrence, dragging the fill with it.
Phoneme features do NOT fix this by themselves — two occurrences are acoustically identical; what
disambiguates them is **global monotonic alignment of the full text sequence** (line 27 comes after
line 8 in the text, so a whole-sequence aligner places it at the later audio occurrence).

## Measurement already exists — use it as the gate

- Test: `KiokuTests/AlignmentQualityTests.testQuality_TsukiiroChainon()`
- Fixture: `KiokuTests/Fixtures/alignment/tsukiiro-chainon.*` (audio.mp3, note.txt, ground-truth.srt,
  tolerance.json = minCoverage 0.95 / medianStartMs 200 / perCueStartMs 500)
- Run: `xcodebuild test -scheme Kioku -only-testing:KiokuTests/AlignmentQualityTests \
  -destination 'platform=iOS Simulator,id=<sim>' -parallel-testing-enabled NO`
- **Step 0 is to run this and record the BASELINE** (it will currently fail cue 27 and likely others).
  Every change below is judged by this number moving, not by eyeballing the device.

## Stack decision (from 2026-07-06 web survey)

There is **no turnkey on-device phoneme forced aligner** for Swift:
- sherpa-onnx forced alignment is an open feature request (k2-fsa/sherpa-onnx#3536), not shipped.
- No Core ML / iOS MMS forced-aligner port exists.
- The proven technique is wav2vec2/MMS CTC forced alignment: PyTorch impl
  `MahmoudAshraf/mms-300m-1130-forced-aligner` (HF); torchaudio `functional.forced_align` is the
  reference DP. wav2vec2 forced-align has been done in MLX (github KalebJS/whispermlx) — the stack
  Kioku already ships (mlx-swift / Qwen3).

Recommended: **MMS (mms-300m-1130) acoustic model ported to MLX**, feeding the existing CTC
forced-align DP; MFA (Montreal Forced Aligner, desktop) used offline to mint more oracle fixtures.
The decisive property for our bug is *global monotonic full-sequence* alignment, not phonemes per se.

## Phases (each gated by the quality test)

1. **Baseline.** Run `testQuality_TsukiiroChainon`; record coverage + median/per-cue error.
   (No code change. Confirms the harness runs and quantifies today's failure.)
2. **Cheap win first — repeat disambiguation in the current aligner.** In `extractAnchors`
   (`SwiftWhisperAlign/.../CTCForcedAligner.swift`), make the chorus handling occurrence-aware:
   when a lyric appears N times in the note, keep the N best time-ordered anchors (one per
   occurrence) instead of collapsing to one. Grade against the test. This may fix it without a new
   model — try before the big port.
3. **Global forced-align spike (if 2 insufficient).** Port mms-300m-1130 to MLX; run whole-song (or
   long-window) monotonic forced alignment over the full note text; feed emissions to the CTC DP.
   Kana→token targets come from Kioku's existing readings (kana→uroman/romaji is near-deterministic;
   no heavy G2P model needed). Behind a flag; grade against the test; expand fixtures via MFA.
4. **Adopt** only if the metric beats the current aligner across ≥3 fixtures (guard against the
   "fixed one song, regressed another" trap that bit the reverted edit).

## Execution handoff

Model port, MFA oracle generation, and running the quality test all require a dev machine / CI with
a simulator + Python/torch/MFA — they cannot run from the headless assistant session. This doc is the
spec; the numbers must come from an environment that can execute the harness.
