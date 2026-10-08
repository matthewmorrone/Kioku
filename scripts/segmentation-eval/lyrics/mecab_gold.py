#!/usr/bin/env python3
"""Builds machine gold for lyric lines: MeCab (ipadic) tokens as gold spans, in score.py's format, with
each token's base form as its head. Run the result through `segcli relabel` to apply Kioku's word
convention; disagreements with the segmenter are then graded by hand from JMdict and grammar, never
from anyone's own segmentation review.
  python3 lyrics/mecab_gold.py lyrics/lines.txt > work/lyrics-mecab.jsonl"""
import json, subprocess, sys

lines = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
parsed = subprocess.run(["mecab"], input="\n".join(lines) + "\n", capture_output=True, text=True, check=True).stdout
blocks = parsed.split("EOS\n")
for i, (line, block) in enumerate(zip(lines, blocks)):
    spans, pos = [], 0
    for row in block.strip("\n").split("\n"):
        if not row:
            continue
        surface, _, feats = row.partition("\t")
        f = feats.split(",")
        at = line.find(surface, pos)
        if at < 0:
            break
        if f[0] != "記号":
            spans.append([at, at + len(surface), f[6] if len(f) > 6 and f[6] != "*" else surface, "", 0])
        pos = at + len(surface)
    print(json.dumps({"id": f"lyric{i}", "s": line, "g": spans}, ensure_ascii=False))
