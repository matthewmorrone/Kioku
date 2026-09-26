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

Environment: `DB=<path>` another dictionary file · `STRATEGY=local` the greedy walk with its demotion list
(held2k 2026-09-21: 80.23 / 3.13; never run two `segcli` at once — they share one UserDefaults domain) · `SPLIT_CLUSTERS=1` the app's default granularity
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
- `lyrics/gold-reviewed.json` — the 38 lyric lines (of 319, from the alignment-fixture songs) where a cut
  of ours fell inside a MeCab word; the user corrected 6. The segmenter was then fixed against these
  lines, so the score is a regression list, NOT a held-out measure; the other 281 lines are unscored.
  Never print whole lyric lines; the scorer prints only the differing fragments.

## Numbers to beat (2026-09-25: table recounted with 200 lexical words; lone-kana penalty)

| Set | exact | cut-through | split |
|---|---|---|---|
| held2k | 88.79 | 0.41 | 2.91 |
| fresh5k | 90.97 | 0.27 | 2.84 |
| kana2k | 85.49 | 1.24 | 3.90 |
| CI fixture (300; not re-run; PR #91) | 91.64 | 0.26 | 2.77 |
| lyric lines reviewed | 37 / 38 | | |

History: greedy + demotion list 80.0 / 3.41 (held2k) → Viterbi on surface ranks 86.55 / 0.91 (PR #83,
tag `segmentation-viterbi-baseline-2026-09-19` + `dictionary-v9`) → fitted overhead + inflection-step
cost 87.22 / 0.80 (#84) → transition costs 88.53 / 0.60 (#86) → deinflection retyped 88.84 / 0.54 (#88)
→ stems, mixed-script words, two-readings pricing (#89–#91; exact dips are gold convention) 88.56 / 0.54
→ particle list no longer gates single kana or breaks unknown runs under the path search (ん|だろう, に|お, 諸君|ら)
→ transitionClampNats 3.0 (from 5.0): a w:よ→noun transition, rare in the prose-trained table but
common at a lyric line break (no punctuation between よ and the next word), priced above the old
clamp and let つたえ｜てよ (both real dictionary entries) undercut つたえて｜よ by ~75 centi-nats.
Re-measured against all three held-out sets, not assumed: kana2k cut-through *improves* (276→269);
held2k and fresh5k are flat within noise (±0.05pp exact). All four numbers above are from paired
`fit` runs (both clamps, one process, `SWIFT_DETERMINISTIC_HASHING=1`) confirmed byte-identical
across repeats — **`segcli run` is not deterministic between separate process launches** without
that env var (~250/2000 kana2k lines differed run to run in this investigation, moving exact by
up to 0.2pp): Swift's per-process hash seed affects Set/Dictionary iteration order somewhere in
tie-breaking. Set `SWIFT_DETERMINISTIC_HASHING=1` for any before/after comparison at this
precision; a plain `run`/`run` diff otherwise mixes real deltas with seed noise. This may also
affect the shipped app (same binary, same non-determinism) — not chased here, out of scope for
this change.
→ table recounted (2026-09-25; 88.78 / 0.41 held2k, 90.97 / 0.27 fresh5k, 85.47 / 1.24 kana2k, lyrics 37/38).
The 2026-09-20 table predated the particle list going greedy-only, so ん and お — top-120 words —
had been counted as BOUNDARY and had no class. LEXICAL_WORDS 120 → 200 then gives って, けど, わ,
しました their own classes (って was 150th in the training half): 120 alone was 82 / 261 cut-throughs
on held2k / kana2k, 200 is 83 / 253 with exact up on all three sets. Classing a conjugated surface
by its best-ranked lemma instead of the union (待って was aux-v via ちまう's まう), counted under
that code, gave 80 / 247 but fresh5k 110 (from 104) — not shipped.
→ lone-kana penalty (SegmenterScoring.loneKanaPenalty, 1.5 zipf): a single kana that is neither a
classed function word nor a counter is rarely a word (ま: 1 gold token in 15,959 occurrences) but
JPDB ranks kana ま at 896, so ま|って beat 待って on a line of its own. Pricing such kana as unranked
broke kana-written 間 (すこしのま, ながいま; kana2k 253 → 258). train2k is flat from 1.0 to 2.5;
1.5 is the smallest that keeps まって whole, 2.0 loses ながいま. Held-out: 88.79 / 0.41, 90.97 / 0.27
(identical output), 85.49 / 1.24.

Known misses on lyrics: ならして after a bare noun — **lyrics drop particles, the transition table
is counted from prose** (noun → verb costs +2.7 nats). The transition weight is irrelevant to the
lyric score. ラララ and に|ついてく, both listed here previously, are fixed by dictionary-v11 alone
(confirmed at the old clamp too) — unrelated to transitionClampNats.

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

2026-09-20: 95.06% → 96.08% resolve (main after PR #91). The gaps were rule **typing**, not only missing rows: `rulesIn`
named the lemma's class, but chaining needs the *inflected form's* class (ている → v1, ない / たい →
adj-i), so no chain crossed a class change and 知っています, ありません, 言われた, 取ろう had no lattice
edge at all. What still fails is Tatoeba convention (勉強する / 私の / 十分な as one token, 食べ|なさい,
だった←だ) — don't chase it. Deliberately omitted: ichidan imperative よ (it would swallow 見てよ —
a different mechanism from つたえてよ-style bare-noun-after-よ misparses, which transitionClampNats
now fixes; see "Numbers to beat").

## Tried and dropped — don't repeat without a new reason

- **16 POS classes** for transitions (any weight, penalties-only, + an expression class): flat. Class
  granularity is the whole result — ~1,100 classes work (own class per common function word, JMdict
  tag + last character for conjugating words, fine → coarse backoff). Weight: cut-through bottoms out
  at 1–1.5; above that only over-splitting grows. Clamp was inert **under 16 classes** — under the
  current ~1,100-class table it is not: see transitionClampNats 3.0 in "Numbers to beat" above.
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
