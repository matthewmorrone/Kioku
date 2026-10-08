# Scores a segcli output file against gold spans.
# usage: score.py gold.jsonl out.txt [--examples N] [--errors-only]
# Per gold token, exactly one of:
#   exact    — one of our segments has the same span
#   straddle — one of our segments partially overlaps it (cuts through it and extends outside), split into:
#     error      — the token cut through is a content word (望ま, どうやら, 中日): a real mistake
#     convention — it is grammar, not content (is_convention: そうな, んだ, はっきりと, 化する): Tatoeba
#                  places that boundary differently from Kioku's convention (悲し|そうな vs 悲しそう|な)
#   split    — we cut inside it, all pieces nested inside the gold span (over-split)
#   merged   — one of our segments strictly contains it (under-split / long unit)
import sys, json, collections, os, sqlite3

def pos_lookup():
    # JMdict POS tags of every spelling (kanji or kana) in the pinned dictionary; None when the
    # dictionary isn't there (then every straddle counts as an error).
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Resources", "dictionary.sqlite")
    if not os.path.exists(path):
        print("score.py: no Resources/dictionary.sqlite, every straddle counts as an error", file=sys.stderr)
        return None
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    tags_by_entry = collections.defaultdict(set)
    for e, pos in db.execute("SELECT entry_id, pos FROM senses"):
        if pos:
            tags_by_entry[e].update(pos.split(","))
    tags = collections.defaultdict(set)
    for table in ("kanji", "kana_forms"):
        for text, e in db.execute(f"SELECT text, entry_id FROM {table}"):
            tags[text] |= tags_by_entry[e]
    return tags

TAGS = pos_lookup()

def is_kana(text):
    # Hiragana, katakana and the marks that go with them (ー, ～, ゛) — a token with no kanji.
    return all("\u3040" <= c <= "\u30ff" or c in "ー～〜" for c in text)

def is_convention(token, head):
    # A cut-through of this gold token is a convention difference, not an error, when the token is
    # grammar rather than content (by JMdict's tags for its headword):
    #   a particle, auxiliary, copula, suffix or conjunction (そうな, でも, だけど, 的に, であった);
    #   a grammar expression written in kana (んだ, ないと, ましょうか, になり, であろう);
    #   an adverb with its と (はっきりと, ゆったりと);
    #   a token led by a suffix or prefix (化する, お座り).
    if TAGS is None:
        return False
    tags = TAGS.get(head, set()) | TAGS.get(token, set())
    if tags & {"prt", "suf", "conj", "adj-pn"} or any(t.startswith(("aux", "cop")) for t in tags):
        return True
    if (not tags or "exp" in tags) and is_kana(token):
        return True
    if "adv-to" in tags and token.endswith("と"):
        return True
    lead = TAGS.get(token[0], set())
    return bool(lead & {"suf", "pref"}) and not lead & {"n", "v5r", "v1"} or (token[0] in "おご" and "pref" in lead)

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
                kind = "convention" if is_convention(sentence[a:b], head) else "error"
                counts[kind] += 1
                for s in bad:
                    straddlers[s[2]] += 1
                if len(examples) < n_examples and (kind == "error" or "--errors-only" not in sys.argv):
                    examples.append((kind, sentence, sentence[a:b], " | ".join(s[2] for s in segs)))
            elif len(overlapping) == 1:
                counts["merged"] += 1
                mergers[overlapping[0][2]] += 1
            else:
                counts["split"] += 1

g = counts["gold"]
print(f"sentences {counts['sentences']}  (misaligned {counts['misaligned_sentences']})  gold tokens {g}")
for k in ("exact", "straddle", "split", "merged"):
    print(f"  {k:9s} {counts[k]:7d}  {100 * counts[k] / g:6.2f}%")
    if k == "straddle":
        for sub in ("error", "convention"):
            print(f"    {sub:10s} {counts[sub]:5d}  {100 * counts[sub] / g:6.2f}%")
print("top straddling segments:", straddlers.most_common(40))
print("top merging segments:", mergers.most_common(25))
for kind, sentence, token, ours in examples:
    print(f"  [{kind}] gold「{token}」 in {sentence}\n      ours: {ours}")
