#!/usr/bin/env python3
"""
Generate a ground-truth SRT for an alignment quality fixture using stable-ts
with the large-v3 Whisper model. This is the "oracle" the on-device aligner's
output is compared against by AlignmentQualityTests.

stable-ts (https://github.com/jianfch/stable-ts) wraps openai-whisper with
better timestamp stability — it post-processes Whisper's coarse segment-level
timings against the audio energy envelope to tighten cue boundaries. Combined
with the large-v3 model (~3 GB, runs on Mac in minutes), it produces
fixture-grade timings that the on-device tiny/base model can be measured
against.

Usage:
    python3 scripts/generate-alignment-oracle.py \\
        --audio path/to/song.mp3 \\
        --text path/to/lyrics.txt \\
        --name <fixture-name> \\
        --out-dir KiokuTests/Fixtures/alignment

    # Writes four files into --out-dir:
    #   <name>.audio.<ext>
    #   <name>.note.txt
    #   <name>.ground-truth.srt
    #   <name>.tolerance.json
    #
    # Files are flat-named (no subdirectory) because Xcode's synchronized file
    # groups flatten subdirectories when copying test-bundle resources. The
    # `<name>.<part>.<ext>` convention keeps fixtures distinct at the bundle
    # root while still being easy to group at a glance on disk.

    # Spot-check the produced ground-truth.srt by ear before trusting it as
    # an oracle. The whole point is to have something more reliable than the
    # on-device aligner — if the oracle is wrong, the tests measure the
    # wrong thing.

Setup (one-time):
    pip install -U stable-ts
    # If stable-ts complains about ffmpeg: brew install ffmpeg

The script writes three files into the output dir:
  - audio.mp3            (copied from --audio)
  - note.txt             (copied from --text, the lyric script the aligner uses)
  - ground-truth.srt     (oracle output from stable-ts large-v3)
  - tolerance.json       (default thresholds; edit per fixture as needed)
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

DEFAULT_TOLERANCE = {
    # Minimum fraction of ground-truth cues that must have a matching output
    # cue within the per-cue tolerance below. 0.95 = at most 5% of GT cues
    # can be missing or mis-timed beyond perCueStartMsTolerance.
    "minCoverage": 0.95,
    # Median absolute start-time delta across matched cues. The on-device
    # tiny/base aligner can be ~150ms median off the large-v3 oracle on
    # clean material; 200ms allows headroom.
    "medianStartMsTolerance": 200,
    # Per-cue start-time tolerance for "did the on-device aligner find this
    # cue?" — within 500ms is "close enough" for karaoke highlighting; beyond
    # that the wrong line lights up.
    "perCueStartMsTolerance": 500,
}


def generate_oracle(audio_path: Path, text_path: Path, out_dir: Path, name: str, model_size: str = "large-v3"):
    try:
        import stable_whisper
    except ImportError:
        sys.exit("stable-ts not installed. Run: pip install -U stable-ts")

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {model_size} model (first run downloads ~3 GB)...")
    model = stable_whisper.load_model(model_size)

    # Use stable-ts's align() — true forced alignment that treats the text as a
    # script the audio must follow, not a hint to bias free transcription.
    # transcribe() with initial_prompt would have produced what we saw with the
    # first oracle attempt: the model freely transcribed, dropped the 3 missing
    # lines we were trying to recover, and merged adjacent cues. align() is the
    # right primitive for "given audio + known lyrics, where does each line land
    # in time."
    lyrics = text_path.read_text(encoding="utf-8")
    lines = [ln.strip() for ln in lyrics.splitlines() if ln.strip()]
    print(f"Aligning {audio_path.name} against {len(lines)} lyric lines (forced)...")

    # align() with original_split=True preserves input line breaks as cue
    # boundaries — each note line becomes exactly one SRT cue. Without this
    # flag the aligner ignores newlines and produces its own segmentation,
    # merging 3-5 input lines into each output cue.
    text_for_alignment = "\n".join(lines)
    result = model.align(
        str(audio_path),
        text_for_alignment,
        language="ja",
        original_split=True,
    )

    # Copy inputs alongside the oracle, all prefixed with the fixture name so
    # multiple fixtures coexist at the flat bundle root after Xcode's
    # synchronized-group resource copy.
    audio_dest = out_dir / f"{name}.audio{audio_path.suffix}"
    shutil.copy2(audio_path, audio_dest)

    text_dest = out_dir / f"{name}.note.txt"
    shutil.copy2(text_path, text_dest)

    srt_dest = out_dir / f"{name}.ground-truth.srt"
    result.to_srt_vtt(str(srt_dest), segment_level=True, word_level=False)
    print(f"Wrote oracle SRT: {srt_dest}")

    tolerance_dest = out_dir / f"{name}.tolerance.json"
    if tolerance_dest.exists():
        print(f"Keeping existing {tolerance_dest.name} (delete to regenerate)")
    else:
        tolerance_dest.write_text(json.dumps(DEFAULT_TOLERANCE, indent=2) + "\n")
        print(f"Wrote default {tolerance_dest.name} — adjust per fixture as needed")

    print()
    print("Next steps:")
    print(f"  1. Spot-check {srt_dest} by ear (open the editor, scrub through 3-5 cues)")
    print(f"  2. If the oracle is good, run: KIOKU_RUN_QUALITY_TESTS=1 xcodebuild test ...")
    print(f"  3. If a cue is wrong in the oracle, edit it by hand — these are the source-of-truth files")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--audio", type=Path, required=True, help="Source audio file (mp3/m4a/wav)")
    p.add_argument("--text", type=Path, required=True, help="Lyric text file (one line per cue)")
    p.add_argument("--name", required=True, help="Fixture name; becomes the prefix for all four output files and the test function name")
    p.add_argument("--out-dir", type=Path, default=Path("KiokuTests/Fixtures/alignment"),
                   help="Directory to write fixture files into (default: KiokuTests/Fixtures/alignment)")
    p.add_argument("--model", default="large-v3",
                   help="Whisper model size (large-v3 recommended; medium acceptable; small/base/tiny will produce poor oracles)")
    args = p.parse_args()
    generate_oracle(args.audio, args.text, args.out_dir, args.name, args.model)


if __name__ == "__main__":
    main()
