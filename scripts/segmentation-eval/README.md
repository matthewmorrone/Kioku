# Segmentation eval

Measures the Kioku segmenter against gold tokens at JMdict granularity, from a Mac command line —
no app or device build. `cli/build.sh` compiles the app's **real** segmenter sources, so a number
here is a number about the shipped code.

CI only guards a quality floor (`SegmentationQualityTests.testHeldOutQualityFloor`). Green CI does
not mean good segmentation; this is where quality is actually measured.

## Quick start

```bash
cd scripts/segmentation-eval
./cli/build.sh                      # → work/segcli   (needs Resources/dictionary.sqlite)
python3 unpack-data.py              # data/*.jsonl.gz → work/data/<set>.jsonl + <set>.txt
./work/segcli run < work/data/held2k.txt > work/held2k.out      # ~1 min per 2k sentences; run long sets in the background
python3 score.py work/data/held2k.jsonl work/held2k.out --examples 10
python3 lyrics/score_lyrics.py      # the user-reviewed lyric lines
```

`work/` is gitignored. If the app's source layout changes, `cli/kioku-sources.txt` is the list of
files the CLI compiles — add whatever the compiler reports missing.

`segcli` modes (usage at the top of `cli/main.swift`):

| mode | what it does |
|---|---|
| `run` | the shipped path: bundled transition table, shipped weights |
| `fit <pairs.tsv> <configs> <outdir>` | lattice once per sentence, path search per `WEIGHT CLAMP` line — dozens of settings cost seconds |
| `count <lexical.txt>` | transition class of every gold token, from the app's own classifier (input to the table generator) |
| `explain` | stdin `text<TAB>seg\|seg\|…` → node cost, score, steps, class and transition for the chosen path **and** the wanted one, or which wanted edge is missing from the lattice. Use this before theorising about any single failure. |
| `lemmas` | what each surface resolves to, with scores (input to the deinflection audit) |
| `oracle` | stdin gold jsonl → for each cut-through, whether the gold parse is in the lattice at all and its node-cost margin. On 2026-09-20 half of all cut-throughs had **no lattice edge** for the gold token — measure this before tuning costs. |

Environment: `DB=<path>` another dictionary file · `SPLIT_CLUSTERS=1` the app's default granularity
(particle clusters split; off here because the gold keeps には / ですか whole) · `KIOKU_CHECKOUT=<path>`
read `Resources/` from another checkout.

## What the columns mean

Every gold token lands in exactly one bucket: **exact** (one of our segments has the same span),
**cut-through** (printed as `straddle`: one of our segments partially overlaps it — the real error),
**split** (we cut inside it), **merged** (one of our segments swallows it — often a legitimate long
unit). Exact against Tatoeba also moves with *convention* (gold writes 彼の, 叫び|ながら, して|くれた);
cut-through is the number to trust.

## Data

Gold = Tatoeba "Japanese indices" (the Tanaka Corpus B lines): sentences tokenized into JMdict
headwords by the JMdict maintainers. https://downloads.tatoeba.org/exports/jpn_indices.tar.bz2 (CC-BY).

- `data/held2k`, `data/fresh` (5k), `data/kana2k` — **held-out; never fit anything on these.**
  `kana2k` = held2k with every kanji-bearing token replaced by its MeCab reading (gold boundaries
  kept): a stress test for kana-heavy text. It cannot be regenerated from a script — keep it.
- `data/train2k` — first 2,000 training sentences; fit knobs here, confirm on held-out.
- `data/known.txt` — hand-picked problem lines; check for regressions.
- The full training half (`train.jsonl`, 73k sentences, 22 MB) is not checked in. Rebuild it with
  `prep.py <dir containing jpn_indices.csv>` (odd sentence ids → held-out, even → train); the
  transition-table counts use it **minus its first 2,000 lines**.
- `lyrics/gold-reviewed.json` — lyric lines the user reviewed (from the alignment-fixture songs).
  Never print whole lyric lines; the scorer prints only the differing fragments.

## Numbers to beat (main as of 2026-09-20, PR #91)

| Set | exact | cut-through | split |
|---|---|---|---|
| held2k | 88.56 | 0.54 | 2.89 |
| fresh5k | 90.75 | 0.33 | 2.86 |
| kana2k | 85.18 | 1.54 | 3.69 |
| CI fixture (300) | 91.64 | 0.26 | 2.77 |
| lyric lines reviewed | 35 / 38 | | |

History: greedy + demotion list 80.0 / 3.41 (held2k) → Viterbi on surface ranks 86.55 / 0.91 (PR #83,
tag `segmentation-viterbi-baseline-2026-09-19` + `dictionary-v9`) → fitted overhead + inflection-step
cost 87.22 / 0.80 (#84) → transition costs 88.53 / 0.60 (#86) → deinflection retyped 88.84 / 0.54 (#88)
→ stems, mixed-script words, two-readings pricing (#89–#91; exact dips are gold convention).

Known misses on lyrics: ラララ (in `extras.json`, needs a dictionary rebuild); に|ついてく (an exact cost
tie); ならして after a bare noun — **lyrics drop particles, the transition table is counted from
prose** (noun → verb costs +2.7 nats). The transition weight is irrelevant to the lyric score.

## Regenerating the transition table

Class names come from the app's own `TransitionClass`, so counting and running cannot diverge.
Regenerate after any change to deinflection rules, POS bits or edge pricing.

```bash
tail -n +2001 work/data/train.jsonl > work/train-fit.jsonl        # train2k stays out of the counts
python3 ../calibration/fit_transition_costs.py lexical work/train-fit.jsonl > work/lexical.txt
./work/segcli count work/lexical.txt < work/train-fit.jsonl > work/classes.txt
python3 ../calibration/fit_transition_costs.py pairs work/classes.txt > ../../Kioku/Dictionary/Segmenter/segmenter-transitions.tsv
./cli/build.sh && ./work/segcli run < work/data/held2k.txt > work/held2k.out      # re-measure
```

Before shipping any model change: the repo path (`run`) must reproduce the experiment's output
sentence for sentence; check `data/known.txt` and the named cases in `SegmentationQualityTests`;
and confirm both segmenter construction sites (`ContentView.makeReadResources`, `TestReadResources`)
get the change — they once diverged, CI green while the phone ran the wrong frequency map.

## Deinflection audit

Asks of every gold token: does the surface resolve to the gold headword? Run it after any rules change.

```bash
python3 audit/collect.py work/data/train.jsonl work/data/held2k.jsonl work/data/fresh.jsonl
./work/segcli lemmas < work/audit/surfaces.txt > work/audit/lemmas.txt
python3 audit/audit.py 60          # failures grouped by (class, surface ending → lemma ending), with counts
```

2026-09-20: 95.06% → 96.2% resolve. The gaps were rule **typing**, not only missing rows: `rulesIn`
named the lemma's class, but chaining needs the *inflected form's* class (ている → v1, ない / たい →
adj-i), so no chain crossed a class change and 知っています, ありません, 言われた, 取ろう had no lattice
edge at all. What still fails is Tatoeba convention (勉強する / 私の / 十分な as one token, 食べ|なさい,
だった←だ) — don't chase it. Deliberately omitted: ichidan imperative よ (it would swallow 見てよ).

## Tried and dropped — don't repeat without a new reason

- **16 POS classes** for transitions (any weight, penalties-only, + an expression class): flat. Class
  granularity is the whole result — ~1,100 classes work (own class per common function word, JMdict
  tag + last character for conjugating words, fine → coarse backoff). Weight: cut-through bottoms out
  at 1–1.5; above that only over-splitting grows. Clamp is inert.
- **IPADic's connection matrix**, bucketed or direct: trained for IPADic's lexicon and short units;
  over-splits JMdict units.
- **MeCab short-unit decomposition** of each edge (word + connection costs, left ID of the first unit,
  right ID of the last): exact falls at every weight; one-best analysis of an edge in isolation
  misreads short fragments. Low ceiling anyway — MeCab's own boundaries would veto 32% of our
  cut-throughs and 2.5% of our correct segments (12 collateral per hit).
- **Word-hood ratio** (gold tokens ÷ occurrences of the string) as a node cost: small gain, but it
  imports gold's conventions at useful weights (breaks だけど|きっと). Superseded by transitions.
- **Own rank first** (score an edge by its surface's own rank whenever it has one): raised
  cut-through on every set, broke ケンカ|も|した|けど. What shipped instead: the cheaper of two
  readings (`Segmenter.pricedReading`), and no ichidan stem recovery for a surface that is already a word.
- **A cost on っ-initial edges** crossed by a longer edge: removes legitimate って, fixes nothing.
- `uk`-tag orthography prior, wordfreq patching (invents scores for non-words), discounted rank
  inheritance (1 token in 20k), refitting unknown-text and unranked costs (flat), per-word overhead
  below 8.5 (trades merged for split), inflection-step cost other than 3 (re-fitted twice: flat).

## Not yet tried

Per-pair transition weights trained on the real lattice (structured perceptron) with a
convention-neutral objective (penalise cut-throughs only) — the principled route to 電|気をつけて,
which flips only at a global weight that over-splits. A signal for dropped particles in lyrics.
One lattice edge per reading (が particle vs conjunction). Script-aware unknown cost (small on Tatoeba:
digits are 5% of remaining cut-throughs, katakana 0 — measure on lyrics first). A larger lyric gold set.
