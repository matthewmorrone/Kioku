# Alignment Quality Fixtures

Each subdirectory here is one fixture for `AlignmentQualityTests`. Tests run
the on-device aligner against the fixture's audio + lyric text and compare the
output to a stable-ts large-v3 oracle SRT — measuring how close the on-device
model gets to a SOTA-on-Mac model on the same input.

## Fixture layout

Files are flat-named at the directory root because Xcode's synchronized file
groups flatten subdirectories when copying test-bundle resources. The
`<fixture>.<part>.<ext>` convention keeps fixtures distinct at the bundle root
while still being easy to scan visually on disk:

```
alignment/
├── <fixture>.audio.{mp3,m4a,wav}    Source audio
├── <fixture>.note.txt               Lyric script — one line per expected cue
├── <fixture>.ground-truth.srt       Oracle (from stable-ts large-v3)
└── <fixture>.tolerance.json         Pass/fail thresholds, see Tolerance below
```

The fixture name appears in test function names as `testQuality_<Name>()` (in
`AlignmentQualityTests.swift`). Pick names that survive renaming the song.

## Adding a fixture

1. **Run the oracle generator** with your audio + lyric text:

   ```bash
   python3 scripts/generate-alignment-oracle.py \
       --audio path/to/song.mp3 \
       --text path/to/lyrics.txt \
       --name <fixture-name>
   ```

   First run downloads the large-v3 model (~3 GB). Subsequent runs reuse it
   from `~/.cache/whisper/`.

2. **Spot-check `ground-truth.srt` by ear.** Open it in the Kioku subtitle
   editor (or a desktop SRT editor) and scrub through 3-5 cues. If the oracle
   is wrong, the tests measure the wrong thing — fix it by hand or regenerate
   with a different `initial_prompt`. Common issues:

   - Cue text is right but timing is off (the oracle has a known weak spot)
   - Some cue is missing (large-v3 mis-heard a quiet vocal — usually rare with
     `initial_prompt` set; if it happens, edit the SRT by hand)
   - An extra cue appears (background noise mistaken for vocal — delete it)

3. **Tune `tolerance.json` if needed.** Defaults are conservative; songs with
   particularly fast/slow vocals or heavy reverb may need looser tolerance.

4. **Add the test function** in `KiokuTests/AlignmentQualityTests.swift`:

   ```swift
   func testQuality_<Name>() async throws {
       try await runQualityCheck(fixtureName: "<fixture-name>")
   }
   ```

5. **Add the fixture dir to the Xcode test bundle** so it ships with the test
   target. In Xcode: select the fixture dir, in the File Inspector check the
   KiokuTests target. Or via the pbxproj — fixture dirs are picked up by the
   synchronized group root automatically once the dir exists.

## Tolerance

```json
{
  "minCoverage": 0.95,           // 95% of oracle cues must match within perCueStartMsTolerance
  "medianStartMsTolerance": 200, // median |output.start - oracle.start| ≤ 200ms
  "perCueStartMsTolerance": 500  // a cue is "matched" only if its start is within 500ms of oracle
}
```

`perCueStartMsTolerance` is the practical threshold — beyond ~500ms the wrong
line lights up during karaoke playback, which is the actual user-visible
failure mode this test is guarding against.

## Running the tests

The whole quality suite is slow (Whisper-in-the-loop, 30-90s per fixture).

Each test self-skips when its fixture directory isn't in the test bundle —
adding a fixture (and updating the Xcode test target so the dir ships with
the bundle) makes the corresponding `testQuality_<Name>()` active.

To run all present quality tests:

```bash
xcodebuild test \
    -project Kioku.xcodeproj -scheme Kioku \
    -destination 'platform=iOS Simulator,id=...' \
    -only-testing:KiokuTests/AlignmentQualityTests \
    -parallel-testing-enabled NO
```

To exclude quality tests from a fast-iteration cycle (e.g. when iterating on
unrelated code):

```bash
xcodebuild test ... -skip-testing:KiokuTests/AlignmentQualityTests
```

`-parallel-testing-enabled NO` matches the local-tested invocation; parallel
test runs sometimes fail to clone the destination simulator.

### Why fixture-presence instead of an env var?

We tried `KIOKU_RUN_QUALITY_TESTS=1` and `TEST_RUNNER_KIOKU_RUN_QUALITY_TESTS=1`.
Neither propagates through `xcodebuild test` into the test process running on
the iOS simulator — the env var stops at the xcodebuild process and the test
runner never sees it. Fixture-presence is the trigger instead: a fixture
that exists in the bundle gets run; one that doesn't, doesn't.

## Repo size note

Each fixture adds ~5 MB to the repo (mp3 + small text files). Audio files are
committed directly — not LFS — because the corpus is small (target: <10
fixtures totaling <50 MB). If the corpus grows beyond that, move to Git LFS
or a fetch-on-demand script.
