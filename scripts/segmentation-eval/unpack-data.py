#!/usr/bin/env python3
"""Unpacks data/*.jsonl.gz into work/data/ as <set>.jsonl (gold) and <set>.txt (one sentence per line)."""
import gzip, json, os, glob
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "work", "data")
os.makedirs(out, exist_ok=True)
for path in sorted(glob.glob(os.path.join(here, "data", "*.jsonl.gz"))):
    name = os.path.basename(path)[:-len(".jsonl.gz")]
    lines = gzip.open(path, "rt", encoding="utf-8").read().splitlines()
    open(os.path.join(out, name + ".jsonl"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    open(os.path.join(out, name + ".txt"), "w", encoding="utf-8").write("\n".join(json.loads(l)["s"] for l in lines) + "\n")
    print(name, len(lines), "sentences")
