#!/usr/bin/env python3
"""Kana-written copies of gold sentences for training, the way kana2k was made from held2k: every
kanji-bearing gold token is replaced by its MeCab reading (hiragana), gold boundaries kept. A sentence
is skipped when MeCab's words don't tile one of its kanji tokens exactly, so no copy has a guessed span.

  python3 boundary/kana_copies.py work/data/train.jsonl 2000 > work/data/train-kana.jsonl

The second argument skips that many leading lines (train2k, the validation set, gets no copies).
Needs the mecab command (ipadic)."""
import json, re, subprocess, sys

KANJI = re.compile(r"[㐀-鿿豈-﫿々]")
path, skip = sys.argv[1], int(sys.argv[2])
rows = [json.loads(l) for l in open(path, encoding="utf-8")][skip:]
parsed = subprocess.run(["mecab"], input="\n".join(r["s"] for r in rows) + "\n",
                        capture_output=True, text=True, check=True).stdout.split("EOS\n")


def hiragana(katakana):
    # MeCab readings are katakana; the copies are written the way kana-only text usually is.
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in katakana)


written = skipped = 0
for row, block in zip(rows, parsed):
    s = row["s"]
    # MeCab's words with their offsets in the sentence and their readings ('' when it has none).
    words, pos = [], 0
    for line in block.strip("\n").split("\n"):
        if not line:
            continue
        surface, _, feats = line.partition("\t")
        i = s.find(surface, pos)
        if i < 0:
            break
        f = feats.split(",")
        words.append((i, i + len(surface), f[7] if len(f) > 7 and f[7] != "*" else ""))
        pos = i + len(surface)
    starts = {w[0]: w for w in words}
    out, spans, cursor, ok, changed = [], [], 0, True, False
    for a, b, head, reading, verified in row["g"]:
        out.append(s[cursor:a])
        token = s[a:b]
        if KANJI.search(token):
            # The MeCab words that tile [a, b) exactly, all with readings, or no copy of this sentence.
            pieces, p = [], a
            while p < b and p in starts and starts[p][1] <= b and starts[p][2]:
                pieces.append(starts[p][2])
                p = starts[p][1]
            if p != b:
                ok = False
                break
            token = hiragana("".join(pieces))
            changed = True
        start = sum(len(x) for x in out)
        out.append(token)
        spans.append([start, start + len(token), head, reading, verified])
        cursor = b
    if not ok or not changed:
        skipped += 1
        continue
    out.append(s[cursor:])
    print(json.dumps({"id": row["id"] + "k", "s": "".join(out), "g": spans}, ensure_ascii=False))
    written += 1
print(f"kana copies: {written} written, {skipped} skipped", file=sys.stderr)
