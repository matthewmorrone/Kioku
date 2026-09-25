#!/usr/bin/env python3
"""Builds the segmenter's transition table (Kioku/Dictionary/Segmenter/segmenter-transitions.tsv).

The eval harness (scripts/segmentation-eval, its work/segcli) supplies the inputs, so
every class name comes from the app's own TransitionClass code:

  fit_transition_costs.py lexical train.jsonl > lexical.txt
      the commonest short kana words in the gold tokens; each gets a class of its own
  segcli count lexical.txt < train.jsonl > classes.txt
      one line per sentence, "start,end,className" per gold token
  fit_transition_costs.py pairs classes.txt > segmenter-transitions.tsv
      "A <tab> B <tab> PMI" for every class pair the counts have an opinion about

PMI(A,B) = ln[ observed(A,B) / expected(A,B) ], expected = the count if the classes met by chance.
SMOOTHING pseudo-counts on both shrink a thinly attested pair toward 0. A pair is written at up
to four levels — full/full, full/coarse, coarse/full, coarse/coarse, where coarse drops a
conjugating class's ending ("v5:て" → "v5") — and only where that level has MIN_EVIDENCE observed or
expected pairs; the app backs off through the same levels in the same order.

The gold index skips names, numbers and punctuation, so tokens either side of a gap are NOT
adjacent: a gap, like the start and end of a sentence, is the BOUNDARY class.

Fit the weight on train2k only, confirm on held-out; keep train2k out of the counts.
"""
import collections, json, math, re, sys

BOUNDARY = "BOUNDARY"
SMOOTHING = 5.0
MIN_EVIDENCE = 5.0
LEXICAL_WORDS = 200


def coarse(name):
    """Mirrors TransitionClass.coarse: a word's own class has nothing coarser."""
    return name if name.startswith("w:") else name.split(":")[0]


def lexical(gold_path):
    """Prints the LEXICAL_WORDS most frequent gold tokens that are 1–4 hiragana."""
    counts = collections.Counter()
    for line in open(gold_path, encoding="utf-8"):
        record = json.loads(line)
        counts.update(record["s"][a:b] for a, b, *_ in record["g"])
    kana = re.compile(r"^[ぁ-ゖー]{1,4}$")
    print("\n".join([w for w, _ in counts.most_common() if kana.match(w)][:LEXICAL_WORDS]))


def class_sequences(path):
    """Yields each sentence as a class sequence with boundaries at both ends and at every gap."""
    for line in open(path, encoding="utf-8"):
        tokens = [t.split(",", 2) for t in line.split()]
        if not tokens:
            continue
        seq, position = [BOUNDARY], None
        for start, end, name in tokens:
            if position is not None and int(start) != position and seq[-1] != BOUNDARY:
                seq.append(BOUNDARY)
            if name != BOUNDARY or seq[-1] != BOUNDARY:
                seq.append(name)
            position = int(end)
        if seq[-1] != BOUNDARY:
            seq.append(BOUNDARY)
        yield seq


def pairs(classes_path):
    """Prints the PMI rows, coarsest level first so a finer level's row for the same names wins."""
    sequences = list(class_sequences(classes_path))
    identity = lambda name: name
    rows = {}
    for left_level, right_level in ((coarse, coarse), (coarse, identity), (identity, coarse), (identity, identity)):
        observed = collections.Counter()
        for seq in sequences:
            observed.update((left_level(a), right_level(b)) for a, b in zip(seq, seq[1:]))
        total = sum(observed.values())
        left, right = collections.Counter(), collections.Counter()
        for (a, b), n in observed.items():
            left[a] += n
            right[b] += n
        for a in left:
            for b in right:
                expected = left[a] * right[b] / total
                if max(observed[(a, b)], expected) >= MIN_EVIDENCE:
                    rows[(a, b)] = math.log((observed[(a, b)] + SMOOTHING) / (expected + SMOOTHING))
    for (a, b), pmi in sorted(rows.items()):
        print(f"{a}\t{b}\t{pmi:.4f}")


if __name__ == "__main__":
    {"lexical": lexical, "pairs": pairs}[sys.argv[1]](sys.argv[2])
