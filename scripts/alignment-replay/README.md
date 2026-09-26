# Alignment replay

Replays the app's lyric aligner on the Mac, on exactly what the phone saw, in about a second per
song — so an aligner change can be tried on real device data without a device build or re-align.
`build.sh` compiles the app's **real** post-model pipeline (`CTCAlignmentCore`: dropout and deaf
fill, energy-VAD pin, wordless-intro rule, Viterbi, line timings, repeated-line spreader) from
`SwiftWhisperAlign/Sources`, so a replay is the shipped code. Verified line-for-line against the
phone's saved cues on four songs (2026-09-25).

What it does not cover: vocal isolation and the MMS model itself run only on the phone (or, for the
model, through `stem_emissions.py`). A replay starts from the phone's emission dumps.

## Quick start

```bash
cd scripts/alignment-replay
./build.sh                                              # → work/replay
# Align the song on the phone (Debug build), then read its key from Documents/ctc-debug.log
./pull.sh f814d2a5a65d64f6 nm 49E91496-8D0D-434D-96C9-369978CD000F   # dumps + stem (+ saved cues) → work/nm/
./work/replay work/nm f814d2a5a65d64f6 note.txt --phone work/nm/49E91496-8D0D-434D-96C9-369978CD000F.cues.json
./work/replay work/nm f814d2a5a65d64f6 note.txt --no-deaf | ./score.py nyuumuun-ni-koishi-te ニュームーンに恋して
```

- **The note** must be the lines the phone aligned, one per line, no ♪ markers. For a benchmark
  song that is `KiokuTests/Fixtures/alignment/<fixture>.note.txt`; for your own note, take the
  non-♪ cue texts from the pulled `.cues.json`.
- **Stem keys** for the 12 benchmark fixtures are in `~/Projects/alignment/stemkeys.json`.
  Running `AlignmentQualityTests.testQuality_AllFixtures` on the device writes dumps for all 12;
  the stem cache is capped, so pull right after.
- **`--phone`** marks each line `=`/`≠` against the phone's result: all `=` means the replay is
  faithful before you change anything.

## Scoring

`score.py <fixture> <consensus title>` reads replay output on stdin. Confirmed lines are scored
against the fixture's ground truth, disputed lines (0–0 there) against the Whisper–wav2vec2 voter
window from `~/Projects/alignment/consensus/<title>.disputed.txt` (override with `--consensus` or
`$ALIGNMENT_CONSENSUS`), so the numbers include the hard lines the device test skips. ±0.5 s.

## Testing an audio change

`stem_emissions.py` runs the phone's CoreML model over any 16 kHz mono audio with the app's
windowing. Copy the model off the phone once:

```bash
mkdir -p work/MMSForcedAligner.mlmodelc && for f in analytics/coremldata.bin coremldata.bin metadata.json model.mil weights/weight.bin; do
  mkdir -p "work/MMSForcedAligner.mlmodelc/$(dirname $f)"
  xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier matthewmorrone.Kioku \
    --source "Documents/MMSForcedAligner.mlmodelc/$f" --destination "work/MMSForcedAligner.mlmodelc/$f"
done
```

Then decode the variant audio to 16 kHz (`ffmpeg -i x.m4a -ac 1 -ar 16000 -f f32le x.f32`), run
`stem_emissions.py x.f32 <dir>/<key>.emissions.f32`, put the matching 44.1 kHz stem beside it, and
replay both variants against the same mix dump. This is how the AAC stem cache was validated.

`work/` is gitignored.
