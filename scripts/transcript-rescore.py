#!/usr/bin/env python3
"""
Cross-check SRT alignment by free-transcribing each cue's audio slice.

The question: for each SRT cue C = (start, end, text), if you listen to ONLY
the audio between [start, end] and ask Whisper to transcribe what it hears
(without the lyric as a prompt), does it produce something close to `text`?

If yes → the cue is on the right slice of audio.
If no  → the cue is misaligned (or Whisper can't hear it, but at scale across
         a song the consistent failure mode is alignment drift).

Independence from forced alignment: the existing SRT was produced by
forced-alignment, which conditions on the script. Free-transcribe doesn't see
the script, so its output is a *separate* opinion about what's audible at
that timestamp. The comparison answers the question we actually care about
(\"are the words at the right time?\") instead of the proxy we had before
(\"are the words on top of voiced audio?\").

Usage:
    python3 scripts/transcript-rescore.py <subtitles-folder> \\
        [--only <song-stem>] [--padding-ms 500] [--cer-threshold 0.45] \\
        [--verbose] [--out cer-results.json]

The script transcribes the *original mp3*, not demucs vocals — that keeps the
reference independent of any separation step that may have produced the SRT.
"""

import argparse
import functools
import json
import re
import sys
from pathlib import Path

print = functools.partial(print, flush=True)  # noqa: A001


# ---------------------------------------------------------------------------
# SRT parsing
# ---------------------------------------------------------------------------

_SRT_BLOCK = re.compile(
    r"(\d+)\s*\n"
    r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*\n"
    r"(.+?)(?=\n\s*\n|\n\s*\d+\s*\n|\Z)",
    re.DOTALL,
)


def parse_srt(path: Path) -> list[tuple[float, float, str]]:
    """Returns [(start_s, end_s, text)] for every cue."""
    text = path.read_text(encoding="utf-8")
    def to_s(h, m, s, ms): return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000
    cues = []
    for match in _SRT_BLOCK.finditer(text):
        _, h1, m1, s1, ms1, h2, m2, s2, ms2, body = match.groups()
        cues.append((to_s(h1, m1, s1, ms1), to_s(h2, m2, s2, ms2), body.strip()))
    return cues


# ---------------------------------------------------------------------------
# Japanese text normalization (no external deps)
# ---------------------------------------------------------------------------

# Punctuation we strip before comparing. Mixed because lyric .txt files and
# Whisper outputs both contain a variety of conventions.
_PUNCT = set("、。！？!?「」『』（）()【】[]…・〜ー~,.\"' ：:；;／/\n\r\t　")


def katakana_to_hiragana(s: str) -> str:
    """Shift any katakana character (U+30A1..U+30F6) down by 0x60 to its
    hiragana equivalent. Leaves other characters alone."""
    out = []
    for ch in s:
        c = ord(ch)
        if 0x30A1 <= c <= 0x30F6:
            out.append(chr(c - 0x60))
        else:
            out.append(ch)
    return "".join(out)


def normalize(s: str) -> str:
    """Collapse to a comparison-ready form: katakana → hiragana, strip
    punctuation/whitespace, lowercase Latin. Doesn't try to handle kanji →
    reading (would require a dict lookup; for cue-text-vs-transcript both
    sides should produce similar kanji from the same audio, so we leave kanji
    in place and let edit-distance handle small discrepancies)."""
    s = katakana_to_hiragana(s)
    s = "".join(ch for ch in s if ch not in _PUNCT)
    s = s.lower()
    return s


# ---------------------------------------------------------------------------
# Character Error Rate (Levenshtein / max(len))
# ---------------------------------------------------------------------------

def levenshtein(a: str, b: str) -> int:
    """Standard edit distance. O(len(a)*len(b)). Lyric cues are short so this
    is fine."""
    if not a: return len(b)
    if not b: return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + cost))
        prev = cur
    return prev[-1]


def cer(reference: str, hypothesis: str) -> float:
    """Character error rate: edit_distance / max(len(ref), len(hyp)). Symmetric
    in the limit but anchored to ref length so empty-hypothesis scores 1.0,
    not infinity."""
    if not reference and not hypothesis:
        return 0.0
    return levenshtein(reference, hypothesis) / max(len(reference), len(hypothesis), 1)


# ---------------------------------------------------------------------------
# Whisper free-transcribe of an audio slice
# ---------------------------------------------------------------------------

def _load_model_once(model_size: str):
    if not hasattr(_load_model_once, "_model"):
        try:
            import stable_whisper
        except ImportError:
            sys.exit("stable-ts not installed. Run: pip install -U stable-ts")
        print(f"Loading {model_size} model (first call only)...")
        _load_model_once._model = stable_whisper.load_model(model_size)
    return _load_model_once._model


def transcribe_slice(audio_arr, sr: int, start_s: float, end_s: float, model_size: str) -> str:
    """Free-transcribe (no prompt) a slice of the audio array. Returns the
    concatenated segment text.

    `audio_arr`: numpy array at 16kHz mono (Whisper's required input format).
    Pre-loaded once per song so we don't re-decode the mp3 per cue.

    `start_s`/`end_s`: slice bounds in seconds (already padded by caller).
    Whisper internally pads short clips to 30s with silence, which is fine —
    it just means a 2-second cue gets ~28 seconds of trailing silence on the
    end, which doesn't affect transcription."""
    model = _load_model_once(model_size)
    s = max(0, int(start_s * sr))
    e = min(len(audio_arr), int(end_s * sr))
    if e <= s:
        return ""
    slice_arr = audio_arr[s:e]
    # transcribe (NOT align): Whisper picks segments freely.
    result = model.transcribe(
        slice_arr,
        language="ja",
        verbose=False,
        condition_on_previous_text=False,  # each slice is independent
    )
    return " ".join(seg.text for seg in result.segments).strip()


# ---------------------------------------------------------------------------
# Per-song scoring
# ---------------------------------------------------------------------------

def score_song(
    mp3_path: Path,
    srt_path: Path,
    model_size: str,
    padding_ms: int,
    cer_threshold: float,
    verbose: bool,
) -> dict:
    """Returns {match_rate, mean_cer, n_cues, per_cue: [...]}.

    `padding_ms`: extra audio included on each side of the cue when slicing.
    Helps with cues whose start is slightly late or whose end is slightly
    early. 500ms is enough to catch a syllable on either side without
    bleeding into the previous/next cue (cue gaps are typically >500ms).
    """
    import stable_whisper
    audio_arr = stable_whisper.audio.load_audio(str(mp3_path))
    sr = 16000  # stable_whisper.audio.load_audio resamples to 16k

    cues = parse_srt(srt_path)
    if not cues:
        return {"match_rate": 0.0, "mean_cer": 1.0, "n_cues": 0, "per_cue": []}

    per_cue = []
    matches = 0
    cer_sum = 0.0
    padding = padding_ms / 1000

    for i, (start, end, text) in enumerate(cues):
        hypothesis = transcribe_slice(audio_arr, sr, start - padding, end + padding, model_size)
        ref_norm = normalize(text)
        hyp_norm = normalize(hypothesis)
        c = cer(ref_norm, hyp_norm)
        matched = c < cer_threshold
        if matched:
            matches += 1
        cer_sum += c
        per_cue.append({
            "i": i,
            "start": start,
            "end": end,
            "text": text,
            "transcript": hypothesis,
            "cer": round(c, 3),
            "match": matched,
        })
        if verbose:
            mark = "✓" if matched else "✗"
            print(f"  [{i+1:02d}] {mark} cer={c:.2f}  text={text!r}  whisper={hypothesis!r}")

    return {
        "match_rate": matches / len(cues),
        "mean_cer": cer_sum / len(cues),
        "n_cues": len(cues),
        "matches": matches,
        "per_cue": per_cue,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("folder", type=Path)
    p.add_argument("--only", help="Process only one song (match by mp3 stem)")
    p.add_argument("--model", default="large-v3",
                   help="Whisper model for free transcription (default large-v3)")
    p.add_argument("--padding-ms", type=int, default=500,
                   help="Extra ms on each side of cue when slicing (default 500)")
    p.add_argument("--cer-threshold", type=float, default=0.45,
                   help="CER below this counts as a match (default 0.45). Lyric "
                        "transcription is rough; a stricter threshold (e.g. 0.3) "
                        "may flag too many false-negatives.")
    p.add_argument("--verbose", action="store_true",
                   help="Print every cue's transcript and CER")
    p.add_argument("--out", type=Path, default=Path("transcript-rescore.json"),
                   help="Per-song results JSON (default transcript-rescore.json)")
    args = p.parse_args()

    mp3s = sorted(args.folder.glob("*.mp3"))
    if args.only:
        mp3s = [m for m in mp3s if m.stem == args.only]
        if not mp3s:
            sys.exit(f"--only {args.only!r}: no matching mp3 in {args.folder}")
    if not mp3s:
        sys.exit(f"No mp3s in {args.folder}")

    results = {}
    for i, mp3 in enumerate(mp3s, 1):
        srt = mp3.with_suffix(".srt")
        if not srt.exists():
            print(f"[{i}/{len(mp3s)}] {mp3.stem}: no .srt, skip")
            continue
        print(f"\n[{i}/{len(mp3s)}] {mp3.stem}")
        r = score_song(mp3, srt, args.model, args.padding_ms, args.cer_threshold, args.verbose)
        results[mp3.stem] = r
        print(f"  matched {r['matches']}/{r['n_cues']} cues ({r['match_rate']*100:.0f}%), mean CER {r['mean_cer']:.2f}")

    args.out.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f"\nWrote {args.out}")

    if len(results) > 1:
        rates = sorted(r["match_rate"] for r in results.values())
        print(f"\nMatch-rate distribution across {len(rates)} songs:")
        print(f"  min:    {rates[0]:.2f}")
        print(f"  median: {rates[len(rates)//2]:.2f}")
        print(f"  max:    {rates[-1]:.2f}")


if __name__ == "__main__":
    main()
