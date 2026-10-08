#!/usr/bin/env python3
"""Applies a relabelled gold file's merges to the kana copies made from it (kana_copies.py): a copy has
the same tokens in the same order, so tokens merged in the original are merged in the copy. Resolving
the kana surfaces again would be both slower and less faithful.
  python3 boundary/relabel_kana.py work/data/train.jsonl work/data/train.relabel.jsonl work/data/train-kana.jsonl > work/data/train-kana.relabel.jsonl"""
import json, sys

original, relabelled, kana = sys.argv[1:4]
groups = {}
for oline, rline in zip(open(original, encoding="utf-8"), open(relabelled, encoding="utf-8")):
    o, r = json.loads(oline), json.loads(rline)
    # For each relabelled token, how many original tokens it covers.
    sizes, i = [], 0
    for a, b, *_ in r["g"]:
        n = 0
        while i < len(o["g"]) and o["g"][i][1] <= b:
            i, n = i + 1, n + 1
        sizes.append(n)
    groups[o["id"]] = sizes
for line in open(kana, encoding="utf-8"):
    k = json.loads(line)
    sizes = groups[k["id"][:-1]]
    if sum(sizes) != len(k["g"]):
        sys.exit(f"token count mismatch for {k['id']}")
    merged, i = [], 0
    for n in sizes:
        first, last = k["g"][i], k["g"][i + n - 1]
        merged.append([first[0], last[1]] + first[2:])
        i += n
    k["g"] = merged
    print(json.dumps(k, ensure_ascii=False))
