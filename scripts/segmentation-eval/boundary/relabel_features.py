#!/usr/bin/env python3
"""Swaps a features file's gold labels (y) for those of a relabelled gold file (`segcli relabel`).
The lattice features don't depend on gold, so the segmenter needn't run again.
  python3 boundary/relabel_features.py work/train.features work/data/train.relabel.jsonl > work/train.relabel.features"""
import json, sys

features, gold = sys.argv[1], sys.argv[2]
with open(features, encoding="utf-8") as ff, open(gold, encoding="utf-8") as gf:
    for fline, gline in zip(ff, gf):
        row, record = json.loads(fline), json.loads(gline)
        if "".join(row["c"]) != record["s"]:
            sys.exit(f"line mismatch: {record['s'][:30]}")
        # Gold offsets count unicode scalars; features count Characters (row["c"]).
        to_char = []
        for i, c in enumerate(row["c"]):
            to_char += [i] * len(c)
        n = len(row["c"])
        to_char.append(n)
        labels = [-1] * (n + 1)
        for a, b, *_ in record["g"]:
            start, end = to_char[a], to_char[b]
            for i in range(start + 1, end):
                if labels[i] != 1:
                    labels[i] = 0
            labels[start] = labels[end] = 1
        row["y"] = labels[1:max(1, n)]
        print(json.dumps(row, ensure_ascii=False))
