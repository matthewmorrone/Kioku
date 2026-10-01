# Alignment Quality Fixtures

Each subdirectory here is one fixture for `AlignmentQualityTests`. Tests run
the on-device aligner against the fixture's audio + lyric text and compare the
output to a consensus oracle SRT (Whisper large-v3 via stable-ts + Japanese
wav2vec2 + MMS, built by
~/Projects/alignment/install_consensus_fixtures.py) — lines the voters dispute
carry a 0–0 span and aren't graded.

## Fixture layout

Files are flat-named at the directory root because Xcode's synchronized file
groups flatten subdirectories when copying test-bundle resources. The
`<fixture>.<part>.<ext>` convention keeps fixtures distinct at the bundle root
while still being easy to scan visually on disk:

```
alignment/
├── <fixture>.audio.{mp3,m4a,wav}    Source audio
├── <fixture>.note.txt               Lyric script — one line per expected cue
├── <fixture>.ground-truth.srt       Consensus oracle (stable-ts Whisper + wav2vec2 + MMS)
└── <fixture>.tolerance.json         Pass/fail thresholds, see Tolerance below
```

The fixture name appears in test function names as `testQuality_<Name>()` (in
`AlignmentQualityTests.swift`). Pick names that survive renaming the song.

## Adding a fixture

1. **Build the oracle** in `~/Projects/alignment`: put the song's mp3 and lyric text in
   `oracles/<title>.{mp3,txt}`, produce the three voters' timings (stable-ts Whisper large-v3,
   Japanese wav2vec2, MMS fp32), run `consensus.py` to write `consensus/<title>.srt` and
   `.disputed.txt`, then `install_consensus_fixtures.py` to copy it here as a fixture (it creates
   the audio / note / tolerance files for a song that has none yet).

2. **Spot-check `ground-truth.srt` by ear** in a desktop SRT editor: scrub through 3-5 cues. If
   the oracle is wrong, the tests measure the wrong thing — fix it by hand. Lines the voters
   disputed carry a 0–0 span and aren't graded.

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

The whole quality suite is slow (vocal isolation + the aligner model on each song). It runs on
the phone, not the simulator; `scripts/alignment-replay` reproduces the aligner on the Mac in
about a second per song.

Each test self-skips when its fixture directory isn't in the test bundle —
adding a fixture (and updating the Xcode test target so the dir ships with
the bundle) makes the corresponding `testQuality_<Name>()` active.

To run all present quality tests:

```bash
xcodebuild test \
    -project Kioku.xcodeproj -scheme Kioku \
    -destination 'platform=iOS,id=<device id>' \
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
