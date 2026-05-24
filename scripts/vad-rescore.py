#!/usr/bin/env python3
"""
Voice-activity rescore SRT files using demucs-separated vocals as the
ground-truth signal.

Why not Silero VAD: Silero is trained on speech and dramatically under-detects
sung vocals — on a 216s J-pop song it returned 7-19% "voiced" instead of the
realistic 70-80%. The metric was useless on music.

The signal we use instead: demucs vocals.wav frame-level RMS. demucs has
already separated voice from instrumental, so frames where vocals.wav is loud
contain singing and frames where it's quiet don't. A 5%-of-peak threshold
catches sustained singing while suppressing reverb tails and bleed.

Usage:
    python3 scripts/vad-rescore.py <subtitles-folder> \\
        [--vocals-cache ~/.cache/kioku-alignment-vocals] \\
        [--baseline alignment-vad-baseline.json]

For each <song>.srt + matching cached vocals.wav, compute the fraction of
SRT cue time that overlaps frames where the vocals exceed the RMS threshold.
Songs without a cached vocals.wav are skipped (they need to be run through
the demucs batch first; cache is keyed by mp3 mtime).

Persists scores to baseline.json so re-running after each batch completion
shows the delta vs. the prior SRT.
"""

import argparse
import functools
import json
import re
import sys
from pathlib import Path

print = functools.partial(print, flush=True)  # noqa: A001 — real-time output


# ---------------------------------------------------------------------------
# SRT parsing
# ---------------------------------------------------------------------------

_SRT_TS = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})"
)


def parse_srt_cues(path: Path) -> list[tuple[float, float]]:
    """[(start_s, end_s)] per cue. Handles both comma (SRT) and dot (VTT)
    decimal separators since stable-ts can emit either."""
    def to_s(h: str, m: str, s: str, ms: str) -> float:
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000

    cues = []
    for match in _SRT_TS.finditer(path.read_text(encoding="utf-8")):
        h1, m1, s1, ms1, h2, m2, s2, ms2 = match.groups()
        cues.append((to_s(h1, m1, s1, ms1), to_s(h2, m2, s2, ms2)))
    return cues


# ---------------------------------------------------------------------------
# Voiced-frame detection from vocals.wav
# ---------------------------------------------------------------------------

def voiced_ranges_from_vocals(
    vocals_path: Path,
    frame_ms: float = 50.0,
    peak_threshold: float = 0.05,
    min_voiced_ms: float = 100.0,
) -> list[tuple[float, float]]:
    """Return sorted [(start_s, end_s)] of frames where the demucs vocals
    exceed a relative-RMS threshold.

    `frame_ms`: window length for RMS computation. 50ms is a typical
    speech/music tradeoff — fine enough to catch phoneme-scale events,
    coarse enough that one stray sample doesn't swing the result.

    `peak_threshold`: fraction of the song's peak RMS below which a frame is
    treated as silent. 5% catches sustained vocals while filtering out
    instrumental bleed (demucs separation isn't perfect — quiet residual
    instruments leak into vocals.wav at very low RMS).

    `min_voiced_ms`: voiced ranges shorter than this get dropped. Whisper
    won't align a word to a 50ms blip even if one frame happens to clear the
    threshold; small ranges mostly add noise to the overlap metric.
    """
    import torch
    import torchaudio
    wav, sr = torchaudio.load(str(vocals_path))
    wav = wav.mean(dim=0)  # stereo → mono

    frame_samples = max(1, int(frame_ms / 1000 * sr))
    n_frames = len(wav) // frame_samples
    if n_frames == 0:
        return []

    # Frame-level RMS via reshape + mean (faster than a Python loop).
    trimmed = wav[: n_frames * frame_samples].reshape(n_frames, frame_samples)
    rms = trimmed.pow(2).mean(dim=1).sqrt()
    peak = float(rms.max())
    if peak == 0:
        return []
    thresh = peak * peak_threshold
    voiced_mask = (rms > thresh).tolist()

    # Collapse runs of True frames into (start, end) ranges in seconds.
    ranges: list[tuple[float, float]] = []
    in_run = False
    run_start_frame = 0
    for i, on in enumerate(voiced_mask):
        if on and not in_run:
            in_run = True
            run_start_frame = i
        elif not on and in_run:
            in_run = False
            start_s = run_start_frame * frame_ms / 1000
            end_s = i * frame_ms / 1000
            if (end_s - start_s) * 1000 >= min_voiced_ms:
                ranges.append((start_s, end_s))
    if in_run:
        start_s = run_start_frame * frame_ms / 1000
        end_s = n_frames * frame_ms / 1000
        if (end_s - start_s) * 1000 >= min_voiced_ms:
            ranges.append((start_s, end_s))

    return ranges


# ---------------------------------------------------------------------------
# Overlap metric
# ---------------------------------------------------------------------------

def overlap_fraction(
    cues: list[tuple[float, float]],
    voiced: list[tuple[float, float]],
) -> float:
    """Σ(cue ∩ voiced) / Σ(cue duration). Voiced ranges sorted by start so
    we can break out of the inner loop once they've moved past the cue."""
    if not cues or not voiced:
        return 0.0
    total_cue = sum(e - s for s, e in cues if e > s)
    if total_cue <= 0:
        return 0.0
    total_overlap = 0.0
    for c_start, c_end in cues:
        for v_start, v_end in voiced:
            if v_end <= c_start:
                continue
            if v_start >= c_end:
                break
            total_overlap += min(c_end, v_end) - max(c_start, v_start)
    return total_overlap / total_cue


# ---------------------------------------------------------------------------
# Cached-vocals lookup
# ---------------------------------------------------------------------------

def find_cached_vocals(mp3: Path, cache_dir: Path) -> Path | None:
    """The demucs cache keys on mp3 stem + mtime. Look for any file
    matching <stem>-*.vocals.wav (mtime drift across runs is the common
    cause of cache misses, but we just want *some* vocals file for the
    song, the freshest one will do)."""
    candidates = sorted(
        cache_dir.glob(f"{mp3.stem}-*.vocals.wav"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


# ---------------------------------------------------------------------------
# Baseline persistence + diff
# ---------------------------------------------------------------------------

def srt_signature(path: Path) -> str:
    """mtime + size is sufficient to detect overwrites without a hash pass."""
    st = path.stat()
    return f"{int(st.st_mtime)}-{st.st_size}"


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("folder", type=Path,
                   help="Folder containing <song>.mp3 + <song>.srt pairs")
    p.add_argument("--vocals-cache", type=Path,
                   default=Path.home() / ".cache" / "kioku-alignment-vocals",
                   help="Where the demucs batch caches vocals.wav (default ~/.cache/kioku-alignment-vocals)")
    p.add_argument("--baseline", type=Path, default=Path("alignment-vad-baseline.json"),
                   help="JSON file remembering each song's last-scored SRT (default: alignment-vad-baseline.json)")
    p.add_argument("--peak-threshold", type=float, default=0.05,
                   help="RMS threshold as fraction of song peak (default 0.05 = 5%%)")
    args = p.parse_args()

    baseline = {}
    if args.baseline.exists():
        baseline = json.loads(args.baseline.read_text())

    mp3s = sorted(args.folder.glob("*.mp3"))
    if not mp3s:
        sys.exit(f"No mp3s in {args.folder}")

    print(f"VAD-rescoring {len(mp3s)} songs from {args.folder}")
    print(f"Vocals cache: {args.vocals_cache}")
    print(f"Baseline:     {args.baseline}")
    print(f"RMS threshold: {args.peak_threshold * 100:.0f}% of song peak\n")

    results = []  # (name, score, prior_score)
    skipped_no_vocals = []
    skipped_no_srt = []

    for i, mp3 in enumerate(mp3s, 1):
        srt = mp3.with_suffix(".srt")
        if not srt.exists():
            skipped_no_srt.append(mp3.stem)
            print(f"[{i}/{len(mp3s)}] {mp3.stem}: skip — no .srt")
            continue
        vocals = find_cached_vocals(mp3, args.vocals_cache)
        if vocals is None:
            skipped_no_vocals.append(mp3.stem)
            print(f"[{i}/{len(mp3s)}] {mp3.stem}: skip — no cached vocals.wav (batch hasn't reached it yet)")
            continue

        sig = srt_signature(srt)
        prior = baseline.get(mp3.stem, {})

        # Re-use score if SRT unchanged since last run.
        if prior.get("srt_sig") == sig and "vad_overlap" in prior:
            score = prior["vad_overlap"]
            cached_marker = "(unchanged)"
            prior_score = prior.get("prior_vad_overlap")
        else:
            voiced = voiced_ranges_from_vocals(vocals, peak_threshold=args.peak_threshold)
            cues = parse_srt_cues(srt)
            score = overlap_fraction(cues, voiced)
            cached_marker = ""
            prior_score = prior.get("vad_overlap") if prior.get("srt_sig") != sig else prior.get("prior_vad_overlap")
            baseline[mp3.stem] = {
                "srt_sig": sig,
                "vad_overlap": score,
                "prior_srt_sig": prior.get("srt_sig"),
                "prior_vad_overlap": prior_score,
            }

        delta = ""
        if prior_score is not None:
            d = score - prior_score
            sign = "+" if d >= 0 else ""
            delta = f"  (prior {prior_score:.3f}, Δ {sign}{d:.3f})"

        print(f"[{i}/{len(mp3s)}] {mp3.stem}: {score:.3f} {cached_marker}{delta}")
        results.append((mp3.stem, score, prior_score))

    args.baseline.write_text(json.dumps(baseline, ensure_ascii=False, indent=2))
    print(f"\nWrote {args.baseline}")

    if skipped_no_vocals:
        print(f"\n{len(skipped_no_vocals)} song(s) skipped — no cached vocals.wav yet:")
        for s in skipped_no_vocals:
            print(f"  ⚠  {s}")

    if results:
        scored = sorted(s for _, s, _ in results)
        median = scored[len(scored) // 2]
        print(f"\nVAD-overlap distribution across {len(scored)} scored songs:")
        print(f"  min:    {scored[0]:.3f}")
        print(f"  median: {median:.3f}")
        print(f"  max:    {scored[-1]:.3f}")

    deltas = [(n, s - p) for n, s, p in results if p is not None and abs(s - p) > 1e-6]
    if deltas:
        ds = sorted(d for _, d in deltas)
        wins = sum(1 for d in ds if d > 0)
        losses = sum(1 for d in ds if d < 0)
        print(f"\nDelta vs. prior SRTs across {len(ds)} changed songs:")
        print(f"  median Δ: {ds[len(ds)//2]:+.3f}")
        print(f"  wins (Δ>0):   {wins}")
        print(f"  losses (Δ<0): {losses}")


if __name__ == "__main__":
    main()
