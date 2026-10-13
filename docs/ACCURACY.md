# How accurate is Kioku's furigana and word splitting?

Kioku Reader adds furigana (kana readings above kanji) and splits Japanese text into words you can tap.
Both run entirely on your iPhone: no internet connection and no AI language model. This page compares
them with the open-source Japanese analyzers that many furigana tools are built on, on public data, with
the method and scripts to reproduce every number.

## Summary

- **Word splits.** On web text Kioku was never tuned on, **97.4%** of the places Kioku splits a word fall
  on a real word boundary, against **90.5–91.2%** for MeCab, UniDic and Sudachi.
- **Furigana on literature.** On Japanese fiction, where editors marked the harder words with furigana,
  Kioku chose the right reading for words with more than one reading **76.7%** of the time, against
  **72.0–73.0%** for the others. The lead is statistically significant against each of them.
- **Furigana on everyday sentences.** On held-out Tatoeba sentences Kioku leads each of the others
  (95.7% and 98.9% against 91.2–94.2% and 95.8–96.6%), but Tatoeba is Kioku's home ground; see Data.
- **Furigana on web and business text.** Here Kioku is **level** with the others: **92.2%** against
  **91.9–92.7%**, with no significant difference against any of them. Before Kioku learned to recognize
  web writing it was significantly behind (90.4% on the same test pages).

## What was compared

| Tool | Version | Notes |
|---|---|---|
| **Kioku** | commit `bb5adc2d`, dictionary built 2026-10-13 | The app's own furigana and word-splitting code, run on a Mac |
| MeCab + IPADic | MeCab 0.996, IPADic (Homebrew) | The long-standing default setup |
| UniDic | fugashi 1.5.2, UniDic 3.1.0 | Current standard dictionary for MeCab |
| Sudachi | SudachiPy 0.6.11, sudachidict_core 20260723 | Current; short (A) and long (C) word modes |

Sudachi's two modes gave identical readings, so the readings tables list it once.

## Data

| Set | What it is | Size | Gold standard |
|---|---|---|---|
| **Aozora** | 36 public-domain works by 12 authors from Aozora Bunko (Natsume Sōseki, Akutagawa Ryūnosuke, Miyazawa Kenji, Dazai Osamu, …), modern spelling | 1,340 paragraphs | The furigana the texts' editors added (6,677 words) |
| **KWDLC** | The Kyoto University Web Document Leads Corpus: opening sentences of web pages (shops, services, blogs, news). Only its 700 **test** documents | 2,195 sentences | Every word's boundaries and reading, annotated by hand |
| **Tatoeba** | Kioku's held-out test sentences from Tatoeba's word index | 2,000 + 5,000 sentences | Readings of words with several readings |

Where Kioku's statistics come from, and why none of it is in these test sets:

- **Everyday readings** are counted from other Tatoeba sentences, never these. Tatoeba is Kioku's home
  ground, so the Tatoeba results are shown for completeness; the claims above rest on Aozora and KWDLC.
- **Web readings** are counted from KWDLC's own **training** documents (its `id/train.id` list).
  KWDLC's authors split the corpus by document into training and test parts; this benchmark scores only
  the test part, so no test page was ever counted.
- **Literary readings** are counted from Aozora Bunko works by authors this benchmark does **not** sample.
- **Recognizing the kind of text.** Kioku decides whether a note reads like everyday sentences, web
  pages or literature by comparing its characters with each of the three sources above, and adds that
  kind's reading counts. The weights were chosen on separate held-out data (KWDLC's development documents,
  a tenth of the counted Aozora works kept aside, and 2,000 Tatoeba sentences), not on these test sets.

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
tools was right. The script prints every p-value.

## Results

### Furigana: words with more than one reading

| Set | Words | Kioku | MeCab + IPADic | UniDic | Sudachi |
|---|---|---|---|---|---|
| **Aozora** (literature) | 1,957 | **76.65%** | 72.61% | 72.00% | 73.02% |
| **KWDLC** (web, test documents) | 2,883 | 92.20% | 91.88% | **92.72%** | 92.65% |
| Tatoeba held2k | 1,002 | **95.71%** | 91.22% | 93.71% | 94.21% |
| Tatoeba fresh5k | 2,949 | **98.91%** | 95.83% | 96.51% | 96.58% |

On Aozora, Kioku is significantly better than MeCab (p < 10⁻⁶), UniDic (p < 10⁻⁹) and Sudachi
(p < 10⁻⁶). On KWDLC none of the differences is significant (Kioku against MeCab p = 0.58, UniDic
p = 0.31, Sudachi p = 0.34).

What changed on KWDLC: with everyday reading counts alone, Kioku read 90.44% of these test words right
and was significantly behind each analyzer, leaning towards everyday readings where web writing wants
others (方 → ほう for かた, 日本 → にっぽん for にほん, 等 → など for とう, その後 → あと for ご). Adding
the web counts for notes that read like web pages fixed 67 of those words and broke 16 (p < 10⁻⁷).
On Aozora the literary counts fixed 69 and broke 21 (p < 10⁻⁶); on the Tatoeba sets the changes were
4 fixed / 7 broken and 0 / 3, neither significant. (These before/after counts compare the same code with and
without the register counts, on the previous dictionary; the tables use the current one.)

### Furigana: all words

| Set | Words | Kioku | MeCab + IPADic | UniDic | Sudachi |
|---|---|---|---|---|---|
| **Aozora** | 5,123 | **86.04%** | 82.18% | 83.17% | 84.13% |
| **KWDLC** | 9,096 | 96.81% | 96.92% | **97.25%** | 97.12% |

On all KWDLC words Kioku is level with MeCab (p = 0.57) and Sudachi (p = 0.06) and behind UniDic
(p = 0.01). Since the words with several readings are level, that gap is in the words whose kanji
Kioku's dictionary lists with a single reading.

### Word splits on web text (KWDLC test documents)

| | Kioku | MeCab + IPADic | UniDic | Sudachi (A) | Sudachi (C) |
|---|---|---|---|---|---|
| **Cut precision** | **97.37%** | 90.47% | 90.54% | 90.86% | 91.18% |
| Splits inside a word | 743 of 28,279 | 3,417 of 35,865 | 3,484 of 36,816 | 3,351 of 36,662 | 3,095 of 35,099 |
| Cut-throughs | 146 | 64 | 58 | 31 | 101 |
| … of them KWDLC's convention | 93 | 9 | 6 | 1 | 52 |
| … other | 53 | 55 | 52 | 30 | 49 |

KWDLC treats な/に/だ as part of the word before (本格的な, 一般的に) and fuses のだ/ので; Kioku, like
the JMdict dictionary, keeps 本格的 whole and splits off な. Most of Kioku's cut-throughs are that
difference, which the "convention" row separates. On the rest Kioku is level with MeCab, UniDic and
Sudachi's long-word mode, and behind its short-word mode. Short words are the hardest to cut into, and
they are also the splitting a learner doesn't want: Sudachi (A) splits a word into pieces about four and a
half times as often as Kioku does.

### Splitting the words editors gave furigana (Aozora)

How often a tool's split cuts into one of the 6,677 words the editors marked with furigana:

| Kioku | MeCab + IPADic | UniDic | Sudachi (A) | Sudachi (C) |
|---|---|---|---|---|
| **61** | 94 | 70 | 101 | 67 |

## Caveats

- These are the analyzers many tools are built on, not any particular app; other apps may add their own
  corrections.
- Kioku aims at learner-sized words (食べている as one word), the others at linguistic units
  (食べ|て|いる); the measures above are chosen so that neither is penalized for word size alone.
- Gold standards contain choices people disagree on (なりうる / なりえる, 何だか, 等 as とう or など),
  which count against every tool alike.
- Kioku's literary and web counts come from the same kinds of source as the Aozora and KWDLC test sets
  (other works, other web pages), so those two results show how well it handles text like its sources.
- Kioku's furigana for a word you've corrected by hand is yours; these numbers are its automatic choices.

## Reproducing

`scripts/benchmark/run.sh` downloads the data (KWDLC from GitHub, the Aozora works from the Aozora Bunko
catalogue) and the analyzers into a temporary folder, runs every tool, and prints these tables. It needs
the `mecab` command with IPADic, Python 3, and a Kioku dictionary that has the reading-register tables
(built by `Resources/generate_db.py` since 2026-10-13; `DB=<path>` points the run at it), plus
`Resources/dictionary.sqlite` for the list of words with several readings. Measured 2026-10-13 at Kioku
commit `bb5adc2d`.

KWDLC is released by Kyoto University's Kurohashi-Chu-Murawaki Lab for language research; Kioku ships
only counts derived from it, no text. Aozora Bunko texts are in the public domain. Tatoeba is
CC BY 2.0 FR.
