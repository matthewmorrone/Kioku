#!/usr/bin/env python3
"""Scores the segmenter on the user-reviewed lyric lines (gold-reviewed.json), at the app's default
granularity (particle clusters split). Prints only the differing fragments — never whole lyric lines.
  score_lyrics.py            (expects ../work/segcli; build it with cli/build.sh)"""
import json, os, subprocess
here = os.path.dirname(os.path.abspath(__file__))
gold = json.load(open(os.path.join(here, "gold-reviewed.json"), encoding="utf-8"))
env = dict(os.environ, SPLIT_CLUSTERS="1")
out = subprocess.run([os.path.join(here, "..", "work", "segcli"), "run"], input="\n".join(g["text"] for g in gold) + "\n",
                     capture_output=True, text=True, env=env).stdout.split("\n")
correct, wrong = 0, []
for g, line in zip(gold, out):
    ours = [s for s in line.split("\x1e") if s.strip()]
    if ours == g["segments"]:
        correct += 1
    else:
        wrong.append((" | ".join(s for s in g["segments"] if s not in ours), " | ".join(s for s in ours if s not in g["segments"])))
print(f"{correct}/{len(gold)} reviewed lyric lines fully correct")
for want, got in wrong:
    print(f"  want {want}   got {got}")
