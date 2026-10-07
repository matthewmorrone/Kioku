"""How well near-tie margins (segcli nearties) find the segmenter's real errors.

  python3 score_nearties.py work/data/held2k.jsonl work/held2k.nt.tsv

A segment is wrong when it cuts through a gold token (partial overlap, neither contains the
other: score.py's "straddle"). For each margin threshold: how many wrong segments sit in some
window under it (recall), how many windows and lines that flags, and what share of flagged
windows hold a wrong segment (precision)."""
import json, sys
from collections import defaultdict

gold = [json.loads(l) for l in open(sys.argv[1])]
windows = defaultdict(list)  # line -> [(start, end, chosen, alt, margin)]
for row in open(sys.argv[2]):
    n, s, e, chosen, alt, m = row.rstrip("\n").split("\t")
    windows[int(n)].append((int(s), int(e), chosen, alt, int(m)))

def straddles(a, b, s, e):
    return a < e and s < b and not (a <= s and e <= b) and not (s <= a and b <= e)

wrong_segments = set()   # (line, start, end)
window_wrong = {}        # (line, idx) -> bool
for n, ws in windows.items():
    toks = [(t[0], t[1]) for t in gold[n]["g"]]
    for i, (s, e, chosen, alt, m) in enumerate(ws):
        pieces, pos, bad = chosen.split("|"), s, False
        for p in pieces:
            a, b = pos, pos + len(p); pos = b
            if any(straddles(a, b, ts, te) for ts, te in toks):
                wrong_segments.add((n, a, b)); bad = True
        window_wrong[(n, i)] = bad

total_windows = sum(len(w) for w in windows.values())
print(f"lines {len(gold)}  windows {total_windows}  wrong segments {len(wrong_segments)}")
print(f"{'margin<':>8} {'recall':>8} {'windows':>8} {'lines':>7} {'precision':>9}")
for t in [0, 100, 200, 300, 400, 500, 700, 1000, 1500]:
    caught, flagged, lines, hit = set(), 0, set(), 0
    for n, ws in windows.items():
        for i, (s, e, chosen, alt, m) in enumerate(ws):
            if m >= t: continue
            flagged += 1; lines.add(n)
            if window_wrong[(n, i)]:
                hit += 1
                pos = s
                for p in chosen.split("|"):
                    if (n, pos, pos + len(p)) in wrong_segments: caught.add((n, pos, pos + len(p)))
                    pos += len(p)
    print(f"{t:>8} {len(caught)/max(1,len(wrong_segments)):>8.1%} {flagged:>8} {len(lines):>7} {hit/max(1,flagged):>9.1%}")
