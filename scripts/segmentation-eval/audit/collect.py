#!/usr/bin/env python3
"""Step 1 of the deinflection audit: every distinct gold (surface, headword, reading) with its count
→ work/audit/pairs.json, and the distinct surfaces → work/audit/surfaces.txt.
  collect.py work/data/train.jsonl work/data/held2k.jsonl …
Then:  work/segcli lemmas < work/audit/surfaces.txt > work/audit/lemmas.txt ;  audit.py [N]"""
import collections, json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "work", "audit")
os.makedirs(out, exist_ok=True)
pairs = collections.Counter()
for path in sys.argv[1:]:
    for line in open(path, encoding="utf-8"):
        record = json.loads(line)
        for a, b, head, reading, _ in record["g"]:
            pairs[(record["s"][a:b], head, reading)] += 1
json.dump([[s, h, r, n] for (s, h, r), n in pairs.items()], open(os.path.join(out, "pairs.json"), "w", encoding="utf-8"), ensure_ascii=False)
open(os.path.join(out, "surfaces.txt"), "w", encoding="utf-8").write("\n".join(sorted({s for s, _, _ in pairs})) + "\n")
print("gold tokens", sum(pairs.values()), "| distinct pairs", len(pairs))
