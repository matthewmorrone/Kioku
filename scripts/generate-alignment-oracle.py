#!/usr/bin/env python3
"""
Forced-align Japanese lyrics to audio with stable-ts + Whisper large-v3.

Two modes:

1. Test fixture mode (single song → KiokuTests fixture):
     python3 scripts/generate-alignment-oracle.py \\
         --audio path/to/song.mp3 --text path/to/lyrics.txt \\
         --name <fixture-name> --out-dir KiokuTests/Fixtures/alignment

   Writes flat-named files for AlignmentQualityTests to ingest:
     <name>.audio.<ext>, <name>.note.txt, <name>.ground-truth.srt,
     <name>.tolerance.json

2. Batch refresh mode (every song in a folder, in-place):
     python3 scripts/generate-alignment-oracle.py --batch <folder>

   For every *.mp3 in <folder>, finds <basename>.txt and writes:
     <basename>.srt          forced-aligned SRT (overwrites existing)
     <basename>.TextGrid     Praat IntervalTier (overwrites existing)

   Skips songs without a matching .txt; reports a summary at the end.

Why large-v3: it's the most accurate publicly available Whisper checkpoint.
On a Mac it runs in tens of seconds per song; on iOS-class hardware it
wouldn't fit. We use it on the Mac to produce reference timings that the
on-device tiny/base model is measured against.

Why stable-ts: openai-whisper's plain transcribe() biases the decoder with
initial_prompt but doesn't force the output to follow it. stable-ts adds an
align() primitive that's true forced alignment — the script is the script,
the audio just gets timed against it. Combined with original_split=True
each lyric line becomes exactly one output cue.

Setup (one-time):
    pip install -U stable-ts
    # If stable-ts complains about ffmpeg: brew install ffmpeg
"""

import argparse
import functools
import json
import shutil
import subprocess
import sys
from pathlib import Path

# Force stdout line-buffering so the script's progress prints reach the log
# in real time — without this, redirected output gets block-buffered and the
# Confidence / ✓ written messages don't appear until the script exits. The
# demucs and stable-ts progress bars (going through different streams) aren't
# affected by this; this only fixes our own print() calls.
print = functools.partial(print, flush=True)  # noqa: A001

DEFAULT_TOLERANCE = {
    "minCoverage": 0.95,
    "medianStartMsTolerance": 200,
    "perCueStartMsTolerance": 500,
}


def load_aligner(model_size: str):
    """Returns a stable-ts Whisper model instance. Imports stable-ts on first
    call so the import error message is informative when the package is
    missing."""
    try:
        import stable_whisper
    except ImportError:
        sys.exit("stable-ts not installed. Run: pip install -U stable-ts")
    print(f"Loading {model_size} model (first run downloads ~3 GB, cached after)...")
    return stable_whisper.load_model(model_size)


def audio_duration_seconds(audio_path: Path) -> float:
    """Reads audio duration via ffprobe (ships with ffmpeg). Used as the
    TextGrid xmax. Returns 0.0 if ffprobe isn't available — the TextGrid will
    use the last cue's end time as a fallback instead."""
    try:
        out = subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(audio_path)],
            stderr=subprocess.DEVNULL,
        )
        return float(out.decode().strip())
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return 0.0


def isolate_vocals(audio_path: Path, model_name: str, cache_dir: Path) -> Path:
    """Run demucs source separation, save vocals to a local cache, return the
    cached path.

    Why source separation: Whisper is trained on speech, not music. Feeding it
    a vocal track mixed with drums/bass/instruments produces looser timing
    than feeding it isolated vocals. demucs is the standard separator;
    htdemucs_ft is the highest-quality variant (~750 MB model, ~30-90s per
    song depending on length).

    Why cache outside the source dir: vocals.wav files are large (~10-50 MB
    each at typical sample rates). Storing them in an iCloud-synced source
    folder would bloat sync traffic and disk usage on every device. The local
    cache stays on this machine; re-runs reuse it for free.

    Cache key: source stem + audio mtime. If the audio file is replaced (mtime
    changes), the cache invalidates and demucs runs again. Old cache entries
    accumulate — clean them manually if disk pressure becomes an issue.

    Why subprocess (and not `demucs.api.Separator`): the `demucs.api` module
    was added in versions newer than what pip currently distributes (4.0.1
    here). The CLI entry point (`python -m demucs ...`) is stable across
    versions. The per-song subprocess startup adds ~5s overhead — tolerable
    next to the ~30-90s separation cost itself.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_key = f"{audio_path.stem}-{int(audio_path.stat().st_mtime)}"
    cached = cache_dir / f"{cache_key}.vocals.wav"
    if cached.exists():
        print(f"  Cached vocals: {cached.name}")
        return cached

    print(f"  Separating vocals with {model_name} (first run downloads the model)...")
    # demucs CLI writes to <out_dir>/<model_name>/<audio_stem>/{vocals,no_vocals}.wav
    # with --two-stems=vocals. We use a temp dir and copy just the vocals file
    # into the cache so the cache stays flat (one file per song).
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        try:
            subprocess.run(
                [
                    sys.executable, "-m", "demucs",
                    "--two-stems=vocals",
                    "-n", model_name,
                    "-o", str(tmp_path),
                    str(audio_path),
                ],
                check=True,
            )
        except FileNotFoundError:
            sys.exit("demucs not installed. Run: pip install -U demucs")
        except subprocess.CalledProcessError as exc:
            raise RuntimeError(f"demucs failed: exit {exc.returncode}") from exc

        produced = tmp_path / model_name / audio_path.stem / "vocals.wav"
        if not produced.exists():
            raise RuntimeError(f"demucs didn't produce expected vocals.wav at {produced}")
        shutil.copy2(produced, cached)

    print(f"  Wrote vocals cache: {cached.name}")
    return cached


def align_song(model, audio_path: Path, lyric_text: str):
    """Runs stable-ts forced alignment. Returns the WhisperResult.

    `original_split=True` preserves input line breaks as cue boundaries — each
    note line becomes exactly one output segment. Without it the aligner does
    its own segmentation and merges 3-5 lines per cue, defeating the point of
    feeding it pre-split text."""
    lines = [ln.strip() for ln in lyric_text.splitlines() if ln.strip()]
    print(f"  Aligning {len(lines)} lyric lines against {audio_path.name}...")
    text_for_alignment = "\n".join(lines)
    return model.align(
        str(audio_path),
        text_for_alignment,
        language="ja",
        original_split=True,
    )


def vad_overlap_fraction(result, audio_path: Path) -> float:
    """Fraction of aligned word time that overlaps voice-activity-detected
    audio. Higher = words are landing on actual singing/speech; lower = words
    are stacked on instrumental sections or silence.

    Why this metric: forced alignment will *always* produce output — it
    distributes script tokens across the audio regardless of whether the words
    are actually being sung at that time. The model's own per-word probability
    is a poor signal on music (we tried it; it stayed ~0.5 even on visibly
    broken alignments) because the model is just rating its confidence
    *conditional* on the script being correct, not on its physical placement
    in the audio.

    VAD overlap directly measures the thing that actually goes wrong: cues
    drifting into instrumental breaks or silent gaps. If 90% of word-time
    lands in voiced audio, the timing is plausibly right; if 30% lands in
    silence, the alignment is broken regardless of how confident the model is.

    Runs Silero VAD on the *original mixed* audio (not the demucs vocals — VAD
    on isolated vocals would call everything voiced because the silent
    stretches got stripped out, defeating the metric).

    Returns 0.0 if VAD finds no voice activity or if the alignment has no
    words (both defensive)."""
    try:
        from silero_vad import get_speech_timestamps, load_silero_vad, read_audio
    except ImportError:
        sys.exit("silero-vad not installed. Run: pip install -U silero-vad")

    model = load_silero_vad()
    wav = read_audio(str(audio_path))
    voiced = get_speech_timestamps(wav, model, return_seconds=True)
    # Each entry: {"start": float, "end": float} in seconds. Sort defensively
    # so the intersection loop can early-exit (it's already sorted in practice).
    voiced_ranges = sorted((v["start"], v["end"]) for v in voiced)

    word_spans: list[tuple[float, float]] = []
    for seg in result.segments:
        for word in seg.words:
            if word.start is None or word.end is None:
                continue
            if word.end > word.start:
                word_spans.append((word.start, word.end))

    if not word_spans or not voiced_ranges:
        return 0.0

    total_word_duration = sum(end - start for start, end in word_spans)
    if total_word_duration <= 0:
        return 0.0

    # Intersection: for each word span, sum overlap with voiced regions.
    # Voiced ranges are sorted by start, so we break out once a voiced range
    # starts at or after the word's end (the remaining ranges start even later).
    total_overlap = 0.0
    for w_start, w_end in word_spans:
        for v_start, v_end in voiced_ranges:
            if v_end <= w_start:
                continue
            if v_start >= w_end:
                break
            total_overlap += min(w_end, v_end) - max(w_start, v_start)

    return total_overlap / total_word_duration


def write_textgrid(result, path: Path, audio_duration: float):
    """Writes a Praat-format TextGrid with TWO IntervalTiers:

      1. 'segments': one interval per cue (sentence-level lyric lines).
      2. 'words':    one interval per Whisper word inside each cue.

    Why two tiers: Kioku's TextGridBinder.pickFinestTier picks the tier with
    the most intervals (with "phones"/"words" as preferred name-ties). When
    the only tier is 'segments', the karaoke highlighter gets one checkpoint
    per cue with charLength=full-line, which leaves the word-level overlay
    stuck on the first word and never advancing. Emitting a 'words' tier
    gives it per-word checkpoints to advance through.

    Praat requires that intervals tile [xmin, xmax] without gaps or overlaps;
    empty-text intervals fill silence/instrumental between labeled intervals.

    Format reference: https://www.fon.hum.uva.nl/praat/manual/TextGrid_file_formats.html
    """
    segments = list(result.segments)
    # Use ffprobe-reported duration when available; otherwise fall back to the
    # last segment's end (TextGrid then technically doesn't cover trailing
    # silence but it stays parseable).
    xmax = audio_duration if audio_duration > 0 else (segments[-1].end if segments else 0.0)

    def build_tiled_intervals(entries: list[tuple[float, float, str]]) -> list[tuple[float, float, str]]:
        """Given a list of (start, end, label) tuples, produce a sequence that
        tiles [0, xmax] by inserting empty intervals for gaps. Clamps each
        entry to [last_end, xmax] so out-of-order or past-end timestamps from
        the aligner don't violate Praat's monotonicity requirement."""
        intervals: list[tuple[float, float, str]] = []
        last_end = 0.0
        for entry_start, entry_end, label in entries:
            start = max(entry_start, last_end)
            end = max(start, min(entry_end, xmax))
            if end <= start:
                continue  # zero-width after clamping — skip
            if start > last_end:
                intervals.append((last_end, start, ""))
            intervals.append((start, end, label))
            last_end = end
        if last_end < xmax:
            intervals.append((last_end, xmax, ""))
        return intervals

    # Tier 1 entries: cue-level (one per segment).
    segment_entries = [(seg.start, seg.end, seg.text.strip()) for seg in segments]
    segment_intervals = build_tiled_intervals(segment_entries)

    # Tier 2 entries: word-level. stable-ts attaches per-word timing under
    # segment.words; entries with None timestamps (rare — failed alignment on
    # that word) are skipped. For Japanese lyrics the "words" are typically
    # 1-3 character clusters since the script has no spaces, which is the
    # right granularity for character-level karaoke advancement.
    word_entries: list[tuple[float, float, str]] = []
    for seg in segments:
        for word in seg.words:
            if word.start is None or word.end is None:
                continue
            label = (word.word or "").strip()
            if not label:
                continue
            word_entries.append((word.start, word.end, label))
    word_intervals = build_tiled_intervals(word_entries)

    # Escape double quotes per Praat spec (double them up).
    def escape(s: str) -> str:
        return s.replace('"', '""')

    def write_tier(f, name: str, intervals: list[tuple[float, float, str]]) -> None:
        f.write(f'"IntervalTier"\n"{name}"\n')
        f.write(f"0\n{xmax}\n{len(intervals)}\n")
        for start, end, text in intervals:
            f.write(f'{start}\n{end}\n"{escape(text)}"\n')

    with open(path, "w", encoding="utf-8") as f:
        f.write('File type = "ooTextFile"\n')
        f.write('Object class = "TextGrid"\n\n')
        # Header: xmin xmax <exists> tierCount. Tier count is now 2.
        f.write(f"0\n{xmax}\n<exists>\n2\n")
        write_tier(f, "segments", segment_intervals)
        write_tier(f, "words", word_intervals)


# ----------------------------------------------------------------------------
# Mode 1: single-fixture (KiokuTests/Fixtures/alignment)
# ----------------------------------------------------------------------------

def generate_fixture(audio_path: Path, text_path: Path, out_dir: Path, name: str, model_size: str, min_vad_overlap: float, demucs_model: str | None, cache_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    model = load_aligner(model_size)
    lyric_text = text_path.read_text(encoding="utf-8")
    audio_for_alignment = isolate_vocals(audio_path, demucs_model, cache_dir) if demucs_model else audio_path
    result = align_song(model, audio_for_alignment, lyric_text)

    # VAD runs on the *original* mix (not the demucs vocals) so silent /
    # instrumental sections are still detected as non-voiced.
    overlap = vad_overlap_fraction(result, audio_path)
    print(f"  VAD overlap: {overlap:.3f} (threshold {min_vad_overlap:.3f})")
    if overlap < min_vad_overlap:
        sys.exit(
            f"\nRefusing to write fixture — VAD overlap {overlap:.3f} below threshold {min_vad_overlap:.3f}.\n"
            f"Words landed mostly outside voiced audio — likely the audio and lyric text don't match,\n"
            f"or the alignment is otherwise broken. Verify both files refer to the same song, or pass\n"
            f"--min-vad-overlap 0 to skip the check."
        )

    audio_dest = out_dir / f"{name}.audio{audio_path.suffix}"
    shutil.copy2(audio_path, audio_dest)
    text_dest = out_dir / f"{name}.note.txt"
    shutil.copy2(text_path, text_dest)

    srt_dest = out_dir / f"{name}.ground-truth.srt"
    result.to_srt_vtt(str(srt_dest), segment_level=True, word_level=False)
    print(f"  Wrote {srt_dest.name}")

    tolerance_dest = out_dir / f"{name}.tolerance.json"
    if tolerance_dest.exists():
        print(f"  Kept existing {tolerance_dest.name}")
    else:
        tolerance_dest.write_text(json.dumps(DEFAULT_TOLERANCE, indent=2) + "\n")
        print(f"  Wrote default {tolerance_dest.name} — tune per fixture as needed")

    print()
    print("Next steps:")
    print(f"  1. Spot-check {srt_dest} by ear (3-5 cues)")
    print(f"  2. Run: xcodebuild test -only-testing:KiokuTests/AlignmentQualityTests")


# ----------------------------------------------------------------------------
# Mode 2: batch (refresh every song in a folder, in-place)
# ----------------------------------------------------------------------------

def batch_process(batch_dir: Path, model_size: str, force: bool, min_vad_overlap: float, demucs_model: str | None, cache_dir: Path, only: str | None = None):
    """For each <song>.mp3 in batch_dir that has a matching <song>.txt, run
    forced alignment and write <song>.srt + <song>.TextGrid alongside the
    audio. Existing .srt/.TextGrid are overwritten — they're regenerated
    every batch. Tells the user which songs were skipped and why.

    `only`: if set, restrict processing to a single mp3 whose stem matches
    this string (e.g. --only 素敵だね). Used to redo one song without re-
    discovering the rest of the folder."""
    mp3s = sorted(batch_dir.glob("*.mp3"))
    if only is not None:
        mp3s = [m for m in mp3s if m.stem == only]
        if not mp3s:
            sys.exit(f"--only {only!r}: no matching mp3 in {batch_dir}")
    if not mp3s:
        sys.exit(f"No *.mp3 files in {batch_dir}")

    # Discover work before loading the model so missing-text issues surface fast.
    work: list[tuple[Path, Path]] = []
    skipped_no_text: list[str] = []
    skipped_up_to_date: list[str] = []
    for mp3 in mp3s:
        txt = mp3.with_suffix(".txt")
        if not txt.exists():
            skipped_no_text.append(mp3.stem)
            continue
        srt = mp3.with_suffix(".srt")
        textgrid = mp3.with_suffix(".TextGrid")
        if not force and srt.exists() and textgrid.exists():
            # Both up-to-date if both newer than the audio AND newer than the lyric.
            srt_fresh = srt.stat().st_mtime >= max(mp3.stat().st_mtime, txt.stat().st_mtime)
            tg_fresh = textgrid.stat().st_mtime >= max(mp3.stat().st_mtime, txt.stat().st_mtime)
            if srt_fresh and tg_fresh:
                skipped_up_to_date.append(mp3.stem)
                continue
        work.append((mp3, txt))

    print(f"Batch in {batch_dir}")
    print(f"  Songs found:      {len(mp3s)}")
    print(f"  Missing .txt:     {len(skipped_no_text)}")
    print(f"  Already current:  {len(skipped_up_to_date)} (pass --force to regenerate)")
    print(f"  To process:       {len(work)}")
    if skipped_no_text:
        for s in skipped_no_text[:5]:
            print(f"    ⚠  no .txt: {s}")
        if len(skipped_no_text) > 5:
            print(f"    (+{len(skipped_no_text) - 5} more)")
    if not work:
        print("\nNothing to do.")
        return

    model = load_aligner(model_size)

    ok = 0
    failed: list[tuple[str, str]] = []
    low_overlap: list[tuple[str, float]] = []
    overlap_log: list[tuple[str, float]] = []
    for i, (mp3, txt) in enumerate(work, 1):
        print(f"\n[{i}/{len(work)}] {mp3.stem}")
        try:
            lyric_text = txt.read_text(encoding="utf-8")
            audio_for_alignment = isolate_vocals(mp3, demucs_model, cache_dir) if demucs_model else mp3
            result = align_song(model, audio_for_alignment, lyric_text)
            # VAD on the *original* mix — see vad_overlap_fraction docstring.
            overlap = vad_overlap_fraction(result, mp3)
            overlap_log.append((mp3.stem, overlap))
            print(f"  VAD overlap: {overlap:.3f} (threshold {min_vad_overlap:.3f})")

            if overlap < min_vad_overlap:
                # Don't write outputs — words landed mostly outside voiced
                # audio. Likely a content mismatch between the audio and the
                # lyric text, or a badly broken alignment. Existing
                # .srt/.TextGrid stay untouched so a known-good prior run
                # isn't lost.
                low_overlap.append((mp3.stem, overlap))
                print(f"  ⚠  SKIPPED writing outputs — VAD overlap below threshold.")
                print(f"     Existing .srt and .TextGrid (if any) preserved.")
                continue

            srt_path = mp3.with_suffix(".srt")
            textgrid_path = mp3.with_suffix(".TextGrid")
            result.to_srt_vtt(str(srt_path), segment_level=True, word_level=False)
            duration = audio_duration_seconds(mp3)
            write_textgrid(result, textgrid_path, duration)
            print(f"  ✓ {srt_path.name}")
            print(f"  ✓ {textgrid_path.name}")
            ok += 1
        except Exception as exc:  # noqa: BLE001 — batch must continue past per-song failures
            failed.append((mp3.stem, str(exc)))
            print(f"  ✗ Failed: {exc}")

    print()
    print("=" * 60)
    print(f"Batch complete: {ok} written, {len(low_overlap)} skipped low-overlap, {len(failed)} failed")
    if low_overlap:
        print(f"\nLow VAD overlap (words landed mostly outside voiced audio — verify the lyric .txt matches):")
        for name, ov in low_overlap:
            print(f"  ⚠  {name}: {ov:.3f}")
    if failed:
        print(f"\nFailed:")
        for name, err in failed:
            print(f"  ✗ {name}: {err}")

    # VAD-overlap summary across all processed songs — useful for calibrating
    # the threshold (look at min/median/max to see what's typical for your
    # corpus).
    if overlap_log:
        overlaps = sorted(o for _, o in overlap_log)
        median = overlaps[len(overlaps) // 2]
        print(f"\nVAD-overlap distribution across {len(overlaps)} songs:")
        print(f"  min:    {overlaps[0]:.3f}  ({next(name for name, o in overlap_log if o == overlaps[0])})")
        print(f"  median: {median:.3f}")
        print(f"  max:    {overlaps[-1]:.3f}  ({next(name for name, o in overlap_log if o == overlaps[-1])})")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", default="large-v3",
                   help="Whisper model (large-v3 recommended; medium acceptable; smaller models produce poor oracles)")

    # Mode 1: single fixture
    p.add_argument("--audio", type=Path, help="Source audio (single-fixture mode)")
    p.add_argument("--text", type=Path, help="Lyric text file (single-fixture mode)")
    p.add_argument("--name", help="Fixture name (single-fixture mode)")
    p.add_argument("--out-dir", type=Path, default=Path("KiokuTests/Fixtures/alignment"),
                   help="Fixture output dir (default: KiokuTests/Fixtures/alignment)")

    # Mode 2: batch
    p.add_argument("--batch", type=Path,
                   help="Batch mode: align every *.mp3 in this folder, writing .srt + .TextGrid in-place")
    p.add_argument("--force", action="store_true",
                   help="In batch mode, regenerate even if .srt/.TextGrid are newer than inputs")
    p.add_argument("--only",
                   help="In batch mode, restrict to a single song (match by mp3 stem). "
                        "Useful for redoing one song after a gate rejection.")

    # Content-mismatch guard (both modes)
    p.add_argument("--min-vad-overlap", type=float, default=0.5,
                   help="Refuse to write outputs when the fraction of word time overlapping "
                        "voice-activity-detected audio falls below this (default 0.5; pass 0 to "
                        "disable). Runs Silero VAD on the original mix and checks whether aligned "
                        "words landed on actual singing — directly catches the failure mode where "
                        "cues drift into instrumental breaks or silent stretches. Threshold is a "
                        "rough first cut; recalibrate from the per-corpus distribution printed at "
                        "the end of batch runs.")

    # Demucs source separation (both modes)
    #
    # Off by default: empirical testing on a 16-song J-pop corpus (Sailor Moon
    # OSTs) showed demucs+alignment gave no consistent improvement over raw
    # alignment when measured by an independent metric (Whisper free-transcribe
    # CER against the SRT cue text). It added ~6-8 min/song of GPU time and
    # occasionally produced catastrophically worse alignments (素敵だね: 12 of
    # 32 lyric lines dropped, one cue spanning 209 seconds). The earlier
    # demucs-on-by-default era used a VAD-overlap metric that turned out to be
    # circular (scored demucs SRTs using demucs's own vocal-detection step),
    # which biased the comparison in demucs's favor.
    #
    # Use --demucs explicitly when you have a song whose raw alignment is
    # visibly drifting and you want to try separation as a fallback.
    p.add_argument("--demucs", dest="demucs_enabled", action="store_true",
                   help="Opt in to demucs vocal separation before alignment. Off by default — "
                        "see the comment above this flag for the empirical reason.")
    p.add_argument("--demucs-model", default="htdemucs_ft",
                   help="Model used when --demucs is passed (default htdemucs_ft, higher quality; "
                        "htdemucs is ~4x faster).")
    p.add_argument("--no-demucs", action="store_true",
                   help="Force-disable demucs. Kept for backward compatibility — demucs is now off "
                        "by default, so this flag is redundant unless overriding --demucs.")
    p.add_argument("--cache-dir", type=Path,
                   default=Path.home() / ".cache" / "kioku-alignment-vocals",
                   help="Local cache for demucs-separated vocals (default ~/.cache/kioku-alignment-vocals). "
                        "Cached by source-file mtime; re-runs on unchanged audio reuse the cache.")

    args = p.parse_args()

    # Demucs off by default; --demucs enables it; --no-demucs always wins
    # (lets you script a no-demucs run defensively even if the default flips).
    if args.no_demucs or not args.demucs_enabled:
        demucs_model = None
    else:
        demucs_model = args.demucs_model

    if args.batch is not None:
        if args.audio or args.text or args.name:
            sys.exit("--batch is mutually exclusive with --audio/--text/--name")
        batch_process(args.batch, args.model, args.force, args.min_vad_overlap, demucs_model, args.cache_dir, only=args.only)
    elif args.audio and args.text and args.name:
        generate_fixture(args.audio, args.text, args.out_dir, args.name, args.model, args.min_vad_overlap, demucs_model, args.cache_dir)
    else:
        p.error("Specify either --batch <dir> or all of --audio/--text/--name")


if __name__ == "__main__":
    main()
