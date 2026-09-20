# Scores a segcli output file against gold spans.
# usage: score.py gold.jsonl out.txt [--examples N]
# Per gold token, exactly one of:
#   exact    — one of our segments has the same span
#   straddle — one of our segments partially overlaps it (cuts through it and extends outside): the hard error
#   split    — we cut inside it, all pieces nested inside the gold span (over-split)
#   merged   — one of our segments strictly contains it (under-split / long unit)
import sys, json, collections

gold_path, out_path = sys.argv[1], sys.argv[2]
n_examples = int(sys.argv[sys.argv.index("--examples") + 1]) if "--examples" in sys.argv else 0

counts = collections.Counter()
straddlers = collections.Counter()
mergers = collections.Counter()
examples = []

with open(gold_path, encoding="utf-8") as gf, open(out_path, encoding="utf-8") as of:
    for gline, oline in zip(gf, of):
        rec = json.loads(gline)
        sentence = rec["s"]
        segs = []
        pos = 0
        for part in oline.rstrip("\n").split("\x1e"):
            surface = part.split("\x1f")[0]
            segs.append((pos, pos + len(surface), surface))
            pos += len(surface)
        if pos != len(sentence):
            counts["misaligned_sentences"] += 1
            continue
        counts["sentences"] += 1
        for a, b, head, _reading, _verified in rec["g"]:
            counts["gold"] += 1
            overlapping = [s for s in segs if s[0] < b and s[1] > a]
            if len(overlapping) == 1 and overlapping[0][0] == a and overlapping[0][1] == b:
                counts["exact"] += 1
                continue
            bad = [s for s in overlapping if (s[0] < a or s[1] > b) and not (s[0] <= a and s[1] >= b)]
            if bad:
                counts["straddle"] += 1
                for s in bad:
                    straddlers[s[2]] += 1
                if len(examples) < n_examples:
                    examples.append((sentence, sentence[a:b], " | ".join(s[2] for s in segs)))
            elif len(overlapping) == 1:
                counts["merged"] += 1
                mergers[overlapping[0][2]] += 1
            else:
                counts["split"] += 1

g = counts["gold"]
print(f"sentences {counts['sentences']}  (misaligned {counts['misaligned_sentences']})  gold tokens {g}")
for k in ("exact", "straddle", "split", "merged"):
    print(f"  {k:9s} {counts[k]:7d}  {100 * counts[k] / g:6.2f}%")
print("top straddling segments:", straddlers.most_common(40))
print("top merging segments:", mergers.most_common(25))
for sentence, token, ours in examples:
    print(f"  gold「{token}」 in {sentence}\n      ours: {ours}")
