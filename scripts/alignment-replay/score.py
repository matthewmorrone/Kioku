#!/usr/bin/env python3
"""Scores replay output (stdin) against a benchmark fixture: a line counts when its start is within
±0.5 s of the reference. Confirmed lines use KiokuTests/Fixtures/alignment/<fixture>.ground-truth.srt;
lines the reference voters disagreed on (0–0 in that file) are scored against the window between the
Whisper (W1) and Japanese wav2vec2 (X) votes, read from <consensus dir>/<title>.disputed.txt, so the
hard lines count too instead of being skipped.

Usage: replay … | score.py <fixture> <consensus title> [--consensus DIR]
  DIR defaults to $ALIGNMENT_CONSENSUS or ~/Projects/alignment/consensus.
Prints "hits/scored" then each miss as "line start vs window".
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, '..', '..', 'KiokuTests', 'Fixtures', 'alignment')


def reference(fixture):
    """(text, start) per ground-truth cue; start 0 marks a disputed line."""
    out = []
    for block in open(os.path.join(FIXTURES, f'{fixture}.ground-truth.srt'), encoding='utf-8').read().strip().split('\n\n'):
        lines = block.split('\n')
        m = re.match(r'(\d+):(\d+):(\d+),(\d+)', lines[1])
        out.append((lines[2], int(m[2]) * 60 + int(m[3]) + int(m[4]) / 1000))
    return out


def disputed(consensus_dir, title):
    """text → list of (lo, hi) voter windows, in song order."""
    path = os.path.join(consensus_dir, f'{title}.disputed.txt')
    windows = {}
    if not os.path.exists(path):
        return windows
    for line in open(path, encoding='utf-8'):
        if not line.strip():
            continue
        text, *votes = line.split('  ')
        v = dict(x.split('=') for x in ' '.join(votes).split())
        ws = [float(v[k]) for k in ('W1', 'X') if k in v]
        if ws:
            windows.setdefault(text.strip(), []).append((min(ws), max(ws)))
    return windows


def main():
    args = sys.argv[1:]
    consensus_dir = os.environ.get('ALIGNMENT_CONSENSUS', os.path.expanduser('~/Projects/alignment/consensus'))
    if '--consensus' in args:
        i = args.index('--consensus'); consensus_dir = args[i + 1]; del args[i:i + 2]
    fixture, title = args
    windows = disputed(consensus_dir, title)
    out = []
    for line in sys.stdin:
        if line.strip().startswith('['):
            continue
        m = re.match(r'\s*([\d.]+)\s+([\d.]+)\s+(?:phone.*?[=≠]\s+)?(.*)$', line)
        if m:
            out.append(float(m[1]))
    hits = scored = 0; misses = []; used = {}
    for (text, t), start in zip(reference(fixture), out):
        if t > 0:
            lo = hi = t
        else:
            k = used.get(text, 0); used[text] = k + 1
            if text not in windows or k >= len(windows[text]):
                continue
            lo, hi = windows[text][k]
        scored += 1
        if lo - 0.5 <= start <= hi + 0.5:
            hits += 1
        else:
            misses.append(f'{text[:14]} {start:.1f} vs {lo:.1f}-{hi:.1f}')
    print(f'{hits}/{scored}', ' | '.join(misses))


if __name__ == '__main__':
    main()
