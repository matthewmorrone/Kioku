# How accurate is Kioku's furigana and word splitting?

Kioku Reader adds furigana (kana readings above kanji) and splits Japanese text into words you can tap.
Both run entirely on your iPhone: no internet connection and no AI language model. This page compares
them with the open-source Japanese analyzers that many furigana tools are built on, on public data, with
the method and scripts to reproduce every number.

## Summary

- **Word splits.** On web text Kioku was never tuned on, **96.5%** of the places Kioku splits a word fall
  on a real word boundary, against **90.1–91.0%** for MeCab, UniDic and Sudachi.
- **Furigana on literature.** On Japanese fiction, where editors marked the harder words with furigana,
  Kioku chose the right reading for words with more than one reading **74.2%** of the time, against
  **72.0–73.0%** for the others. The lead is small but statistically significant against each of them.
- **Furigana on web and business text.** Here Kioku was **less** accurate: **91.0%** against
  **92.5–93.1%**. Its reading statistics come from everyday sentences, so it leans towards everyday
  readings where formal writing wants others (その後 → ご, その他 → た, 等 → とう).

## What was compared

| Tool | Version | Notes |
|---|---|---|
| **Kioku** | commit `165b3a35` | The app's own furigana and word-splitting code, run on a Mac |
| MeCab + IPADic | MeCab 0.996, IPADic (Homebrew) | The long-standing default setup |
| UniDic | fugashi 1.5.2, UniDic 3.1.0 | Current standard dictionary for MeCab |
| Sudachi | SudachiPy 0.7.0, sudachidict_core 20260723 | Current; short (A) and long (C) word modes |

Sudachi's two modes gave identical readings, so the readings tables list it once.

## Data

| Set | What it is | Size | Gold standard |
|---|---|---|---|
| **Aozora** | 36 public-domain works by 12 authors from Aozora Bunko (Natsume Sōseki, Akutagawa Ryūnosuke, Miyazawa Kenji, Dazai Osamu, …), modern spelling | 1,340 paragraphs | The furigana the texts' editors added (6,677 words) |
| **KWDLC** | The Kyoto University Web Document Leads Corpus: opening sentences of web pages (shops, services, blogs, news) | 16,051 sentences | Every word's boundaries and reading, annotated by hand |
| **Tatoeba** | Kioku's held-out test sentences from Tatoeba's word index | 2,000 + 5,000 sentences | Readings of words with several readings |

Kioku's reading statistics were counted from other Tatoeba sentences, never from these test sentences, but
Tatoeba is its home ground: the Tatoeba results are shown for completeness, and the claims above rest on
Aozora and KWDLC.

## Method

**Readings.** A word is scored when its kanji form one run and its reading is known. Each tool is judged
only on the words *every* tool put furigana on over exactly the same kanji, so all tools face the same
words. Two kanji are left out for every tool: 私, which UniDic and Sudachi read as the formal わたくし by
design, and 来, which the gold marks with the dictionary reading く even in 来て. "Several readings" means
words whose kanji Kioku's dictionary lists with more than one reading, the words where choosing matters.

**Word splits.** *Cut precision* is the share of a tool's word splits that land on a word boundary in the
gold. Extra or missing splits from different word sizes cost nothing; only a split in the wrong place does.
It needs a gold that marks every boundary, so it is reported for KWDLC only. *Cut-throughs* count words a
tool's split cuts into partway.

**Significance.** Each comparison was checked with McNemar's test on the words where exactly one of the two
tools was right.

## Results

### Furigana: words with more than one reading

| Set | Words | Kioku | MeCab + IPADic | UniDic | Sudachi |
|---|---|---|---|---|---|
| **Aozora** (literature) | 1,960 | **74.23%** | 72.55% | 71.99% | 73.01% |
| **KWDLC** (web) | 20,968 | 91.00% | 92.51% | 92.95% | **93.05%** |
| Tatoeba held2k | 1,002 | **96.01%** | 91.22% | 93.71% | 94.21% |
| Tatoeba fresh5k | 2,947 | **99.02%** | 95.89% | 96.57% | 96.64% |

On Aozora, Kioku is significantly better than MeCab (p = 0.028), UniDic (p = 0.002) and Sudachi
(p = 0.045). On KWDLC it is significantly worse than each (p < 10⁻¹⁷).

### Furigana: all words

| Set | Words | Kioku | MeCab + IPADic | UniDic | Sudachi |
|---|---|---|---|---|---|
| **Aozora** | 5,065 | **85.09%** | 82.11% | 83.14% | 84.09% |
| **KWDLC** | 63,407 | 96.46% | 97.06% | 97.19% | **97.20%** |

### Word splits on web text (KWDLC)

| | Kioku | MeCab + IPADic | UniDic | Sudachi (A) | Sudachi (C) |
|---|---|---|---|---|---|
| **Cut precision** | **96.49%** | 90.09% | 90.34% | 90.61% | 90.97% |
| Splits inside a word | 7,106 of 202,543 | 25,066 of 252,933 | 25,020 of 259,103 | 24,271 of 258,495 | 22,400 of 248,073 |
| Cut-throughs | 1,016 | 554 | 522 | 330 | 838 |
| … of them KWDLC's convention | 614 | 59 | 43 | 14 | 341 |
| … other | 402 | 495 | 479 | 316 | 497 |

KWDLC treats な/に/だ as part of the word before (本格的な, 一般的に) and fuses のだ/ので; Kioku, like
the JMdict dictionary, keeps 本格的 whole and splits off な. Most of Kioku's cut-throughs are that
difference, which the "convention" row separates. On the rest Kioku is second, behind Sudachi's
short-word mode. Short words are the hardest to cut into, and they are also the splitting a learner
doesn't want: Sudachi (A) splits a word into pieces about three and a half times as often as Kioku does.

### Splitting the words editors gave furigana (Aozora)

How often a tool's split cuts into one of the 6,677 words the editors marked with furigana:

| Kioku | MeCab + IPADic | UniDic | Sudachi (A) | Sudachi (C) |
|---|---|---|---|---|
| **64** | 94 | 70 | 101 | 67 |

## Caveats

- These are the analyzers many tools are built on, not any particular app; other apps may add their own
  corrections.
- Kioku aims at learner-sized words (食べている as one word), the others at linguistic units
  (食べ|て|いる); the measures above are chosen so that neither is penalized for word size alone.
- Gold standards contain choices people disagree on (なりうる / なりえる, 何だか), which count against every
  tool alike.
- Kioku's furigana for a word you've corrected by hand is yours; these numbers are its automatic choices.

## Reproducing

`scripts/benchmark/run.sh` downloads the data (KWDLC from GitHub, the Aozora works from the Aozora Bunko
catalogue) and the analyzers into a temporary folder, runs every tool, and prints these tables. It needs
the `mecab` command with IPADic, Python 3, and Kioku's dictionary (`scripts/ensure_dictionary.sh`).
Measured 2026-10-11 at Kioku commit `165b3a35`.

KWDLC is released by Kyoto University for language research. Aozora Bunko texts are in the public domain.
Tatoeba is CC BY 2.0 FR.
