# Segmentation eval

Measures the Kioku segmenter against gold tokens at JMdict granularity, from a Mac command line —
no app or device build. `cli/build.sh` compiles the app's **real** segmenter sources, so a number
here is a number about the shipped code.

This is where segmentation quality is measured; the app's test suite runs only by hand.

## Quick start

```bash
cd scripts/segmentation-eval
./cli/build.sh                      # → work/segcli   (needs Resources/dictionary.sqlite)
python3 unpack-data.py              # data/*.jsonl.gz → work/data/<set>.jsonl + <set>.txt
./work/segcli run < work/data/held2k.txt > work/held2k.out      # ~1 min per 2k sentences; run long sets in the background
python3 score.py work/data/held2k.jsonl work/held2k.out --examples 10
python3 lyrics/score_lyrics.py      # the user-reviewed lyric lines
python3 named_cases.py              # named cases (data/named-cases.tsv): each pins one decision; seconds
```

Run all of these before a segmentation change goes up — they are the check; CI's Tests workflow is
manual-only and doesn't cover segmentation any better.

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
| `helpers` | stdin surfaces → `surface<TAB>lemma + helper…`: the helper words deinflection folds into each surface (DeinflectionRule.helper), as the lookup sheet's lemma line names them |
| `compounds` | stdin surfaces → `surface<TAB>base + auxiliary` for each one the lookup sheet's subtitle names as a compound verb (CompoundVerbSplitter). Feed it every common verb headword to review the splits after changing the splitter or `DerivationAnalyzer.auxiliaryVerbs`. |
| `oracle` | stdin gold jsonl → for each cut-through, whether the gold parse is in the lattice at all and its node-cost margin. On 2026-09-20 half of all cut-throughs had **no lattice edge** for the gold token — measure this before tuning costs. |

Environment: `DB=<path>` another dictionary file · `STRATEGY=local` the greedy walk with its demotion list
(held2k 2026-09-21: 80.23 / 3.13; never run two `segcli` at once — they share one UserDefaults domain) · `KIOKU_CHECKOUT=<path>`
read `Resources/` from another checkout · `NO_EXTRAS=1` skip the built-in Custom Words. By default segcli
copies the dictionary to a temp file and writes `Resources/extras.json` into the copy with the app's
`CustomWordApplier`, as the app does at runtime (the dictionary build no longer bakes them in); the
source file is never written. Without them lyrics drop to 32/38 (シャイ|ニー, ユ|アラブ).

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
- The full training half (`train.jsonl`, 73k sentences, 22 MB) is not checked in and no copy is kept.
  Rebuild it with `prep.py <dir>` after downloading Tatoeba's current `jpn_indices.csv` into `<dir>`
  (https://downloads.tatoeba.org/exports/jpn_indices.tar.bz2; odd sentence ids → held-out, even →
  train); the transition-table counts use it **minus its first 2,000 lines**.
- `lyrics/gold-reviewed.json` — the 38 lyric lines (of 319, from the alignment-fixture songs) where a cut
  of ours fell inside a MeCab word; the user corrected 6. The segmenter was then fixed against these
  lines, so the score is a regression list, NOT a held-out measure; the other 281 lines are unscored.
- `lyrics/review-corrected-2026-09-20.txt` — the user's review of all 319 lines (cuts as ` | `),
  including the 281 they left as correct; the source the 38 gold lines were taken from.
  Never print whole lyric lines; the scorer prints only the differing fragments.

## Numbers to beat (2026-10-08: boundary model, weight 4, dictionary-v15)

| Set | exact | cut-through | split |
|---|---|---|---|
| held2k | 89.92 | 0.30 (62) | 2.71 |
| fresh5k | 92.12 | 0.18 (71) | 2.49 |
| kana2k | 86.37 | 1.10 (223) | 3.68 |
| lyric lines reviewed | 38 / 38 | | |
| named cases | 62 / 63 | | |

Readings (`segcli furigana` + `score_readings.py`, 2026-10-10): held2k 95.12%, fresh5k 96.85%. Frequency
order alone was 91.09% / 94.79%; the rest is the context pass (FuriganaResolver+ContextualReadings): Tatoeba's
reading counts (`scripts/calibration/count_reading_contexts.py` → `Kioku/Read/Furigana/reading-contexts.tsv`;
94.50% / 96.97% on their own) and, where they keep the frequency reading, Apple's tokenizer for suffix and
counter readings (94.03% / 95.90% on its own). Tried and worse: the transition table's classes on each
reading's JMdict tags (no setting beat 91.09%: the table never saw a kanji's readings apart), and the
on-device model writing sentences in kana (3 fixed, 10 broken). Candidates come from every lemma a surface can
be (甘く as 甘い, 入り as 入る): +2 / −1. Also tried and dropped: Apple only for kanji the counts never saw
(held2k −5), and blending each neighbour class with its broader class (−82 as P-backoff, ±2 as a bonus).

Without the model (`NO_BOUNDARY_MODEL=1`): held2k 88.87 / 75, kana2k 85.66 / 240, fresh5k 90.75 / 117,
lyrics 35 / 38, named 61 / 63. Measured through `segcli run` with `SWIFT_DETERMINISTIC_HASHING=1`;
`boundary/eval.sh` gives the same cut-throughs. The model, its training and the conventions it was
relabelled to are described under "Boundary model" below.

History (held2k exact / cut-through %): greedy + demotion list 80.0 / 3.41 → Viterbi on surface ranks 86.55 / 0.91 (PR #83,
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
→ table recounted (2026-09-25). The 2026-09-20 table predated the particle list going greedy-only,
so ん and お — top-120 words — had been counted as BOUNDARY and had no class: held2k 82 / 0.40,
kana2k 261, fresh5k 103. LEXICAL_WORDS 200 (って, けど, わ, しました classed) scored better on
held-out (83 / 253 / 105 cut-throughs, exact +0.1) but broke がいようのみにしよう → がい|よ|うのみにしよう
in SegmentationQualityTests — kept at 120. Classing a conjugated surface by its best-ranked lemma
instead of the union (待って was aux-v via ちまう's まう) gave fresh5k 110 cut-throughs, all real
errors (もそう, ２|つもっている) — not shipped.
→ lone-kana penalty (SegmenterScoring.loneKanaPenalty, 1.5 zipf): a single kana that is neither a
classed function word nor a counter is rarely a word (ま: 1 gold token in 15,959 occurrences) but
JPDB ranks kana ま at 896, so ま|って beat 待って on a line of its own. Pricing such kana as unranked
broke kana-written 間 (すこしのま, ながいま; kana2k +5 cut-throughs). 1.5 is the smallest that keeps
まって whole; 2.0 loses ながいま. Held-out: held2k 88.72 / 0.40, kana2k 85.31 / 1.28; lyrics 37/38.
→ Jiten frequency list (2026-09-30, dictionary-v13), replacing JPDB, which has no licence. Same Yomitan
layout, so the import is unchanged; three things had to change with it. (1) Jiten ranks words, not
readings (72% of multi-reading words tie), so surface_readings breaks ties by JMdict reading order.
(2) Jiten ranks kana strings nobody writes as a word (まお, いよ, がそ; 71k spellings JPDB left
unranked), so a two-kana string pays loneKanaPenalty too unless JMdict marks it a common reading
(priority tags, now imported from EDRDG's XML — jmdict-simplified only carries a boolean). Without
the common exemption the penalty only worked between 0.29 and 0.40 (よみ and なる broke above it).
(3) The rank offset and per-word overhead were re-swept on train2k (offset 6.8/7.2, overhead
8.25/8.75): cut-through flat at 90–91 throughout, exact only trades split for merged — not changed.
Against JPDB on the same code: held2k 79 vs 82 cut-throughs, kana2k 250 vs 237 (55 Jiten-only, 42
JPDB-only: word-by-word rank disagreement on kana strings like では / ですが / してやる, no pattern).
Named-case failure: がいよう|の|み, a real error. Jiten ranks kana み (#6244, JPDB left it unranked), and み
escapes the lone-kana penalty through its JMdict counter entry. Limiting that exemption to kana after a
numeral fixes 外用|のみ|に but costs kana2k (こ for 子 loses it: 250 → 253 cut-throughs with particles exempt),
and the line then flips to がい|よ|うのみにしよう because Jiten ranks kana がいよう at #348,063 — not shipped.
そう|です is the kept convention (MeCab's; the user prefers the split), not a failure. Lyrics: 本当に kept whole (JMdict's adverb; convention), ならして as before.

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

## Boundary model (`boundary/`)

A small character-level network gives P(cut) at every gap between characters from the characters
around it and the lattice's evidence there (`BoundaryFeatures.swift`); the path search adds
−weight·ln P as per-gap costs (`BoundaryCosts.swift`, `Segmenter+BoundaryModel.swift`). The shipped
model (`Kioku/Dictionary/Segmenter/SegmentBoundaryNet.mlpackage`, 2.2 MB, CPU-only) averages two
networks: one trained on Tatoeba's training half, one on the same data plus kana copies relabelled
to Kioku's word convention (`segcli relabel`: tokens merge when the segmenter resolves the pair to
the first token's word — 泣き|たく → 泣きたく, キス|して → キスして). Each fixes cases the other gets
wrong (またたく, 会いたい / 雨|なのに, がいよう|のみ).

```bash
MODE=features WORKERS=3 python3 run_parallel.py work/data/train.jsonl > work/train.features   # lattice features
python3 boundary/train.py work/train.features work/boundary-path                              # ~2 min/epoch, 3 threads
boundary/eval.sh work/boundary-path "0 2 3 4" train2k train2k-kana                            # pick the weight here
python3 boundary/export_coreml.py work/boundary-path,work/boundary-relabel                     # writes the app's model
```

The full training half comes from `prep.py` (see Data); kana copies from `boundary/kana_copies.py`,
relabelling from `segcli relabel` + `boundary/relabel_kana.py` + `boundary/relabel_features.py`.
The weight is chosen on train2k and its kana copies, never on the held-out sets. Above weight 4 the
model starts pushing Tatoeba's conventions (と|いう).

## Lyric gold without anyone's review (`lyrics/mecab_gold.py`)

All 319 lyric lines, gold from MeCab (ipadic) relabelled to Kioku's convention — no one's own
segmentation review goes into it. Disagreements are graded from JMdict and grammar; on 2026-10-08
the three cut-throughs were all MeCab's mistakes on kana (ひとり|ぼっ|ちよ, なら|し|てよ|ん|で, 眩し|げに),
so Kioku has 0 real errors on the set.

```bash
sed 's/ | //g' lyrics/review-corrected-2026-09-20.txt | grep -v '^\s*$' | sort -u > work/lyrics-lines.txt
python3 lyrics/mecab_gold.py work/lyrics-lines.txt | ./work/segcli relabel > work/lyrics-gold.jsonl
python3 -c "import json;[print(json.loads(l)['s']) for l in open('work/lyrics-gold.jsonl')]" | ./work/segcli run > work/lyrics.out
python3 score.py work/lyrics-gold.jsonl work/lyrics.out
```

## Known fails, left on purpose

- **あめ|だ|の|せんべい** (want あめ|だの|せんべい, the listing particle; sample note キャラメルと飴玉).
  Not a frequency error: on the same scale as the rank list (wordfreq runs ~1.7 Zipf higher for
  function words), だの's rank is accurate — it's a rare particle losing a near-tie. Raising function
  words to their raw wordfreq fixed it only by inflating every particle (broke 雨|なのに → 雨|な|のに).
  The only remaining fix is a rule for the paired AだのBだの pattern, which would be a one-particle
  exception; dropped 2026-10-08.
