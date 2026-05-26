#!/usr/bin/env python3
"""
Calibrate the POS-bigram constants in SegmenterScoring.swift against IPADic's
CRF-trained connection-cost matrix.

Inputs (all in this directory or the app bundle):
  - left-id.def  : context_id -> IPADic feature CSV  (EUC-JP)
  - right-id.def : context_id -> IPADic feature CSV  (EUC-JP)
  - ../../Resources/MeCab/ipadic/matrix.bin : packed connection-cost matrix

For every POS-class bigram bucket used by SegmenterScoring.transitionCost,
gathers all matrix cells whose endpoints fall into that bucket and reports
the median cost. The median is our empirical replacement for the hand-tuned
magic numbers.

Run:
    python3 Scripts/calibration/calibrate_viterbi_costs.py

The script prints both raw IPADic-scale medians (typically -10000..+10000)
and rescaled values that fit alongside the existing node-cost constants
(viterbiDictionaryBonus = -3, viterbiLengthRewardPerCharacter = -6, etc.).
Pick a divisor based on the printed spread.
"""

from __future__ import annotations

import struct
from pathlib import Path
from statistics import median
from typing import Iterable

HERE = Path(__file__).resolve().parent
MATRIX_PATH = HERE.parent.parent / "Resources" / "MeCab" / "ipadic" / "matrix.bin"
LEFT_ID_PATH = HERE / "left-id.def"
RIGHT_ID_PATH = HERE / "right-id.def"

ENCODING = "euc-jp"

# POS buckets we use in SegmenterScoring.transitionCost. Each maps IPADic's
# Japanese feature strings to a Swift-side bucket name. The first feature
# field is the top-level POS; sub-fields refine it.
def classify(features: list[str]) -> set[str]:
    if not features:
        return set()
    top = features[0]
    sub = features[1] if len(features) > 1 else "*"
    sub2 = features[2] if len(features) > 2 else "*"

    out: set[str] = set()
    # Skip sentinels — id 0 (BOS/EOS) is never a real transition endpoint.
    if top == "BOS/EOS":
        return out

    if top == "名詞":
        out.add("noun")
        if sub == "固有名詞":
            out.add("properNoun")
        elif sub == "代名詞":
            out.add("pronoun")
        elif sub == "数":
            out.add("numeric")
        elif sub == "接尾":
            out.add("suffix")
            if sub2 == "助数詞":
                out.add("counter")
    elif top == "動詞":
        out.add("verb")
    elif top == "形容詞":
        out.add("adjective")
    elif top == "助詞":
        out.add("particle")
    elif top == "助動詞":
        # IPADic has no separate copula POS — だ/です are auxiliaries. We
        # double-tag so the "copula" buckets calibrate against the same
        # cells as "auxiliary" ones (matches how transitionCost treats them).
        out.add("auxiliary")
        out.add("copula")
    elif top == "接続詞":
        out.add("conjunction")
    elif top == "感動詞":
        out.add("interjection")
    elif top == "副詞":
        out.add("adverb")
    elif top == "接頭詞":
        out.add("prefix")
    # 記号 (symbol), フィラー, その他, 連体詞 — intentionally left unbucketed.
    return out


def parse_id_def(path: Path) -> dict[int, set[str]]:
    """Returns {context_id: set_of_bucket_names}."""
    buckets: dict[int, set[str]] = {}
    with open(path, encoding=ENCODING) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            head, _, rest = line.partition(" ")
            if not rest:
                continue
            cid = int(head)
            feats = rest.split(",")
            buckets[cid] = classify(feats)
    return buckets


def read_matrix(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    lsize, rsize = struct.unpack_from("<HH", data, 0)
    return lsize, rsize, data[4:]


def cells_for_bucket_pair(
    left_buckets: dict[int, set[str]],
    right_buckets: dict[int, set[str]],
    lsize: int,
    rsize: int,
    body: bytes,
    prev_bucket: str,
    next_bucket: str,
) -> list[int]:
    """Gather every matrix cost where prev's right_id ∈ prev_bucket and next's left_id ∈ next_bucket.

    MeCab's connection cost lookup is:  matrix[prev.rcAttr + next.lcAttr * lsize].
    So prev_bucket maps over right_id-side IDs, next_bucket over left_id-side IDs.
    """
    # right_buckets is the right-id.def mapping (where rcAttr of prev lives).
    # left_buckets  is the left-id.def  mapping (where lcAttr of next lives).
    prev_rids = [cid for cid, b in right_buckets.items() if prev_bucket in b]
    next_lids = [cid for cid, b in left_buckets.items() if next_bucket in b]

    if not prev_rids or not next_lids:
        return []

    costs: list[int] = []
    for lid in next_lids:
        row_base = lid * lsize
        # Bulk-unpack the row, then index by prev_rids.
        row = struct.unpack_from(f"<{lsize}h", body, row_base * 2)
        for rid in prev_rids:
            costs.append(row[rid])
    return costs


# (prev_bucket, next_bucket) -> Swift constant name. Order mirrors the
# transitionCost dispatch chain in SegmenterScoring.swift.
BUCKET_PAIRS: list[tuple[str, str, str]] = [
    # --- Original 9 (kept under their existing Swift names) ---
    ("particle",  "particle",  "viterbiParticleParticlePenalty"),
    ("prefix",    "particle",  "viterbiPrefixParticlePenalty"),
    ("counter",   "particle",  "viterbiCounterParticlePenalty"),
    ("noun",      "noun",      "viterbiNounNounPenalty"),
    ("noun",      "particle",  "viterbiNounParticleReward"),
    ("adjective", "particle",  "viterbiAdjParticleReward"),
    ("verb",      "auxiliary", "viterbiVerbAuxiliaryReward"),
    ("verb",      "particle",  "viterbiVerbParticleReward"),
    ("particle",  "noun",      "viterbiParticleNounReward"),

    # --- Rewards added in Rung 2 ---
    ("adverb",    "verb",      "viterbiAdverbVerbReward"),
    ("adverb",    "adjective", "viterbiAdverbAdjectiveReward"),
    ("prefix",    "noun",      "viterbiPrefixNounReward"),
    ("numeric",   "counter",   "viterbiNumericCounterReward"),
    ("noun",      "suffix",    "viterbiNounSuffixReward"),
    ("noun",      "verb",      "viterbiNounVerbCompoundReward"),
    ("noun",      "auxiliary", "viterbiNounAuxiliaryReward"),
    ("adjective", "auxiliary", "viterbiAdjectiveAuxiliaryReward"),
    ("adjective", "noun",      "viterbiAdjectiveNounReward"),
    ("auxiliary", "auxiliary", "viterbiAuxiliaryAuxiliaryReward"),
    ("copula",    "particle",  "viterbiCopulaParticleReward"),
    ("copula",    "auxiliary", "viterbiCopulaAuxiliaryReward"),
    ("pronoun",   "particle",  "viterbiPronounParticleReward"),
    ("properNoun","particle",  "viterbiProperNounParticleReward"),
    ("interjection","particle","viterbiInterjectionParticleReward"),
    ("particle",  "verb",      "viterbiParticleVerbReward"),
    ("particle",  "adjective", "viterbiParticleAdjectiveReward"),
    ("adverb",    "adverb",    "viterbiAdverbAdverbReward"),

    # --- Penalties added in Rung 2 ---
    ("auxiliary", "verb",      "viterbiAuxiliaryVerbPenalty"),
    ("auxiliary", "noun",      "viterbiAuxiliaryNounPenalty"),
    ("auxiliary", "adjective", "viterbiAuxiliaryAdjectivePenalty"),
    ("prefix",    "prefix",    "viterbiPrefixPrefixPenalty"),
    ("prefix",    "verb",      "viterbiPrefixVerbPenalty"),
    ("prefix",    "auxiliary", "viterbiPrefixAuxiliaryPenalty"),
    ("suffix",    "verb",      "viterbiSuffixVerbPenalty"),
    ("suffix",    "noun",      "viterbiSuffixNounPenalty"),
    ("copula",    "verb",      "viterbiCopulaVerbPenalty"),
    ("copula",    "noun",      "viterbiCopulaNounPenalty"),
    ("particle",  "auxiliary", "viterbiParticleAuxiliaryPenalty"),

    # --- Conjunction broadcasts to ANY next bucket; we calibrate against the
    # union of all next-side IDs (excluding BOS/EOS). ---
    ("conjunction", "*",       "viterbiConjunctionAnyReward"),
]


def main() -> None:
    left_buckets = parse_id_def(LEFT_ID_PATH)
    right_buckets = parse_id_def(RIGHT_ID_PATH)
    lsize, rsize, body = read_matrix(MATRIX_PATH)

    assert lsize == rsize == 1316, f"unexpected matrix dims: {lsize}x{rsize}"

    print(f"# IPADic matrix: {lsize}×{rsize} cells, {len(body)//2} int16 costs")
    print(f"# Tagged left-side IDs: {sum(1 for v in left_buckets.values() if v)} / {len(left_buckets)}")
    print(f"# Tagged right-side IDs: {sum(1 for v in right_buckets.values() if v)} / {len(right_buckets)}")
    print()

    results: list[tuple[str, str, str, int, int]] = []
    for prev_b, next_b, swift_name in BUCKET_PAIRS:
        if next_b == "*":
            # Broadcast: gather over all next-side IDs except BOS/EOS sentinels (id 0).
            prev_rids = [cid for cid, b in right_buckets.items() if prev_b in b]
            costs: list[int] = []
            for lid in range(1, lsize):  # skip BOS/EOS
                row = struct.unpack_from(f"<{lsize}h", body, lid * lsize * 2)
                for rid in prev_rids:
                    costs.append(row[rid])
        else:
            costs = cells_for_bucket_pair(
                left_buckets, right_buckets, lsize, rsize, body, prev_b, next_b
            )

        if not costs:
            results.append((prev_b, next_b, swift_name, 0, 0))
            continue

        med = int(median(costs))
        results.append((prev_b, next_b, swift_name, med, len(costs)))

    # Print the raw table so we can inspect spread before picking a divisor.
    name_w = max(len(r[2]) for r in results)
    print(f"{'pair':<28}{'name':<{name_w + 2}}{'median':>10}{'cells':>10}")
    print("-" * (28 + name_w + 2 + 10 + 10))
    for prev_b, next_b, swift_name, med, n in results:
        pair = f"{prev_b}→{next_b}"
        print(f"{pair:<28}{swift_name:<{name_w + 2}}{med:>10}{n:>10}")

    # Pick a divisor so the constants land in roughly [-200, +200], comparable
    # to the existing node-cost magnitudes (viterbiDictionaryBonus=-3,
    # viterbiLengthRewardPerCharacter=-6, viterbiUnknownPenalty=6, etc.).
    # 100 is a clean round number that keeps relative ratios intact.
    DIVISOR = 100
    print()
    print(f"# Rescaled by /{DIVISOR} (matches existing node-cost magnitudes):")
    print()
    print("    // Empirically derived from IPADic matrix.bin via Scripts/calibration/calibrate_viterbi_costs.py.")
    print(f"    // Each value is median(matrix[r][l]) / {DIVISOR} across all (r ∈ prev_bucket_right_ids, l ∈ next_bucket_left_ids).")
    for prev_b, next_b, swift_name, med, n in results:
        scaled = round(med / DIVISOR)
        print(f"    static let {swift_name} = {scaled}  // raw median = {med} (n={n})")


if __name__ == "__main__":
    main()
