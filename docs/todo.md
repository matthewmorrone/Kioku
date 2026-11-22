# Todo

Open Kioku work only. Finished items are deleted, not ticked; git history has them. Each entry is
written so a new session can pick it up cold.

## Known errors

Places where Kioku's segmentation or furigana is verifiably wrong, checked by hand against JMdict (2026-10-11,
held2k and a 15-case kana2k sample, segmenter at d2943c30). Delete an entry once a run shows it fixed.
Each line: Kioku's cut → the right cut, then the sentence (kana2k: the kanji original it was made from).

Not listed: cut-throughs that are only convention differences with the gold data. In these, Kioku's
piece is itself a JMdict suffix or expression used as such (２|回目, 知らない|振りをしています, 冷め|ないうちに,
足りない|っていう, 理性|の|タガがはずれる, 名状|すべからず). `score.py` counts them as "convention" when the
cutting piece is a JMdict suffix, expression or conjunction as written; an inflected one (振りをしています)
still shows as "error", since the scorer has no lemmas.

Segmentation first, then readings (the "Reading errors (remaining)" note on the phone).

### Segmentation: held2k

- ６|月末 → ６月|末 — ６月末に参加者を募ったら…
- 中|日間 → 中日|間 — 中日間は本当にお互いを知り合うところまでは到達していない。
- オート|ロックする → オートロック|する — ドアを閉めたらオートロックするということはありません。
- どう|やらない → どうやら|ない — 資質は、どうやらないようだ。
- パシ|ら|されなきゃ → パシらされ|なきゃ — ジュース買う為にパシらされなきゃなんないんだか (the short causative パシらす has no rule: as a grammar-table row it reads every transitive 〜す verb
  as a causative, 動かす → 動く, 減らす → 減る (2026-10-12), so it needs a gate admitting it only where JMdict has
  no 〜す verb of that spelling; see deinflection-grammar.json auxiliaryCoverage.leftOut)
- ５|日間 → ５日|間 — このオファーは５日間有効です。 (JMdict's 日間 is only "daytime")
- ブチキレ|ないほう → ブチキレない|ほう — ブチキレないほうがおかしい。 (ないほう resolves to 内包)
- 新年|度に|は → 新|年度|には — 零細小売店などは新年度には利益を上げるでしょう。

### Segmentation: other lines

- よい|ま|会い|に|行く → よ|いま|会い|に|行く — よいま会いに行く

### Segmentation: kana2k (sample of 15 of its 106 "error" straddles; the rest are unaudited)

- と|しまえ → とし|まえ — ３年前に東京へ来て以来
- にしゃ|ん|はい → に|しゃんはい — 判断するに上海からか。
- さん|じゅうぶん → さんじゅう|ぶん — 三十分以内に完了します。
- しん|だからといって → しんだ|からといって — 死んだからといって霊的世界を
- にき|さいして → に|きさい|して — 「はじめにお読み下さい」に記載してあります。
- ちゅうかん|て|す|とか|あ → ちゅうかんてすと|かあ — 次は中間テストかあ。
- は|だが → はだ|が — 肌がヒリつくどころか
- のに|ん|しょうをうける → の|にんしょう|を|うける — 定款の認証を受ける必要があります。
- はつ|どうして → はつどう|して — 春機が発動して
- あべない|かく → あべ|ないかく — 安倍内閣は
- はすう|に|ちかん → は|すうにちかん — 数日間放置して
- で|なくなったら → でなく|なったら — アクが出なくなったら (で read as the copula)
- はい|まで|た → は|いま|でた — 列車は今出たところだ。

### Readings (the "Reading errors (remaining)" note on the phone)

The note's entries and grouping, minus は何回目 (the app reads 何 as なん now; the note still lists it).
The other 30 still showed the wrong reading in the app's saved furigana for the note on 2026-10-12. Each line: the snippet, what the app shows, and the right
reading. The "Disputed" group lists cases where our reading is standard or both readings are; they are
kept here because the note keeps them.

#### Fixable: segmentation (1)

- 中日間は — 中|日間 ちゅう|にっかん, should be 中日|間 ちゅうにち|かん

#### Fixable: too few examples (1)

- 十万石を — いし, should be こく

#### Undecidable: meaning or rare reading (18)

- いただいた方に — ほう, should be かた
- の方だ — ほう, should be かた
- +西日） — にしび, should be せいにち
- 、西日の — にしび, should be せいにち
- ベス下手より — へた, should be しもて
- 件の七不思議 — けん, should be くだん
- の出店が — しゅってん, should be でみせ
- 、玲姉」「 — あね, should be ねえ
- は小節を — しょうせつ, should be こぶし
- を弄っている。 — いじ, should be まさぐ
- と御札が — おさつ, should be おふだ
- の性です — せい, should be さが
- の汚れでした。 — よご, should be けが
- を称え、 — とな, should be たた
- で空を — そら, should be くう
- 素の — もと, should be す
- 便数が — かず, should be すう
- 時刻通りに — とお, should be どお

#### Disputed: our reading is standard or both are (10)

- 新車時３００ — とき, should be どき
- 作成等の — ら, should be など
- なり得る。 — え, should be う
- を細切りに — ほそぎ, should be こまぎ
- 、何だか恥ずかしい — なん, should be なに
- 酷い暴言を吐いた方 — は, should be つ
- は如何ですか？ — いかが, should be どう
- 、家に — いえ, should be うち
- 出ていない闇夜だった。 — あんや, should be やみよ
- 侮り難いぜ、 — がた, should be にく

### Finding more

```bash
cd scripts/segmentation-eval   # after cli/build.sh and unpack-data.py
./work/segcli run < work/data/held2k.txt > work/held2k.out
python3 score.py work/data/held2k.jsonl work/held2k.out --examples 100 --errors-only
```
Then judge each "[error]" line against JMdict before adding it here. For readings: `segcli furigana` +
`score_readings.py`, or the phone note (copy it off with `xcrun devicectl device copy from`, Notes/<id>.json).

### Left on purpose

Wrong, but every fix found so far breaks more than it fixes.

- **あめ|だ|の|せんべい** (want あめ|だの|せんべい, the listing particle; sample note キャラメルと飴玉).
  Not a frequency error: on the same scale as the rank list (wordfreq runs ~1.7 Zipf higher for
  function words), だの's rank is accurate — it's a rare particle losing a near-tie. Raising function
  words to their raw wordfreq fixed it only by inflating every particle (broke 雨|なのに → 雨|な|のに).
  The only remaining fix is a rule for the paired AだのBだの pattern, which would be a one-particle
  exception; dropped 2026-10-08.

## Classical forms that are also particles

過ぎし日 comes out 過ぎ|し|日: the classical past し (き's 連体形) has no rule. Neither do ず's and ぬ's に and
ね, たり's と, つ's て/てよ. Each is a single kana that is also one of the commonest particles, and with a rule
it changed modern sentences at every classical step weight tried, 2 to 8 (よ|ね → よね, へ|と → へと,
あて|に → あてに; 2026-10-12, held2k/fresh), so pricing (SegmenterScoring.classicalStepWeight) cannot keep
it. A fix needs a different signal: for instance admitting the form only right after a verb's 連用形/未然形
in the lattice, never as a bare edge. The omissions are in deinflection-grammar.json omitted, each with the
measurement. Also still split at weight 3, and worth rechecking with any such change: 散りぬる, 消えぬれば, 来にけり.

## Word embeddings: follow-ups

The reading model is a per-kanji logistic regression on fastText vectors (scripts/calibration/reading_model.py,
Kioku/Read/Furigana/ReadingContext.swift; offline harness in scripts/segmentation-eval/cv/). The 50,000 vectors
are in the dictionary (`word_vectors`). These are the ideas not yet built, in rough order of payoff. Measure each
with the cv harness before shipping (10-fold sign test, not held2k moves of a few tokens).

- **Reading failures after the swap.** 等 など→とう (twice), 人 ひと→にん, 力 ちから→りょく, 位 くらい→い, 気味
  ぎみ→きみ. The neighbour's grammatical form decides these and the averaged embedding loses it. Try features for
  the neighbour's surface ending (last one or two kana); one-hot classes added +0.12 pt offline, this is the same
  signal without the segmenter's class names.
- **Phrase vote is fixed at +2.** The Apple vote was retuned 2026-11-21 against the embedding model (segcli reads
  `APPLE_VOTE` / `PHRASE_VOTE`; cli/build.sh patches them in): 2 stays. train2k correct at 0/1/2/3/4/6: 1146 / 1148 /
  1151 / 1150 / 1145 / 1142; held2k at 0/2/3/4/6: 1191 / 1196 / 1193 / 1192 / 1183. Raising it to rescue short-note
  様 costs accuracy. The phrase vote is untested; either retune it the same way or add both as regression features.
- **NDL furigana: built into the pipeline, full build run 2026-11-17 (25 min, 374 modelled readings), not committed.**
  `generate_db.py` streams the 14 NDL shards (`import_ndl_tokens`, scripts/calibration/ndl_corpus.py), trains the
  reading model on Tatoeba plus 662k NDL tokens with a source column; `--skip-ndl` omits it. Gates on that dictionary:
  named cases 104/104; held2k 1196 correct (95.15%, +1 vs without NDL); fresh 4022 (97.06%, −7 vs 4029). The per-line
  runs showed 詩人の様に, 幻の様に: よう → さま and 街家 いえ → か, but segcli classifies each line's register on its own and these
  short lyric lines read as "web" (KWDLC's counts add +2.84 for さま over よう); the app classifies a whole note once, and the
  lyrics as one note (`WHOLE=1`) read everyday: all four 様 → よう, 家 → いえ. Gate lyrics and notes with `WHOLE=1` per note, not per
  line. On the 26 notes copied from the phone (847 lines, per line), 12 readings change: 7 better (鳴り止まぬ 止 と→や, 告げる風
  ふう→かぜ, 時を超え じ→とき ×3, 何よりも なん→なに, の様燃え さま→よう), 1 neutral (明日 あす→あした), 4 per-line artefacts as above.
  Not yet re-run per note. Still to decide: whether the −7 on fresh is worth it.
- **Smaller or own vectors.** 100-dimension vectors cut the size 3×; vectors trained on our own segmented text
  would drop the CC BY-SA licence. fastText's `.bin` (subword, covers unknown words) is the heavy option: much
  larger to fetch and to ship. Only worth it if the licence or size matters.
- **Rare kanji share strength.** Features crossed with reading type so kanji with few examples borrow from the
  rest. One version tried (2026-11-21, `cv/role.py`): each reading's JMdict part of speech scored against the
  neighbours' classes with the segmenter's own transition PMI, added to the regression's log-probability. Null: +8
  tokens at weight 0.25 (p=0.37), worse from 1.0 up (−26 at 1.0, −243 at 2.0). 様 is already 31/35 in Tatoeba's
  folds (88.6%), and NDL holds no 様 with の before it, so the lyric よう/さま misses are a domain gap in the
  training text (the Apple vote covers them), not a missing feature. A second version, also null (`cv/kana.py`,
  `segcli kanacost`): the kana of each candidate substituted into a ±12 character window and priced by the
  segmenter's own Viterbi cost, subtracted from the regression's log-probability. On 10,026 held-out tokens the
  best weight (0.25, deltas clipped at 4 nats) gained 9 tokens net (p=0.35); from 0.5 up it lost (−90 at 0.5
  unclipped, −467 at 1.0). Path costs of different strings aren't comparable (length and word frequency
  dominate). It got the four 様 lines I tried by hand right, which the Tatoeba folds do not reproduce.
  A third (`cv/lr_kana.py`, `reading_model.kana_token`): Tatoeba's kana-written tokens (様に written ように: 22,830
  usable, 2,659 of them 様 read よう) as extra training contexts, each source with its own flag column so the prior
  stays the kanji-written tokens'. Kanji-written Tatoeba cannot show the gain (1 of its 36 様 has の before it): the
  fold test is neutral (+1 token, p=1). Scored on held-out kana-written contexts with the flag at 0 it is the
  difference: 様 81.4% → 97.0%, all kanji with kana tokens 57.8% → 81.9%. In the build (`--skip-ndl`) the lyric
  `の様に` lines read よう from the model's own context (さま −2.0 to −3.0 against −0.3 to −1.4 before), held2k 1196,
  fresh 4028 (−1 vs 4029 without NDL or kana), named cases 104/104. Not yet measured with NDL on, nor by Apple vote 0.
  A fourth, null (`cv/role_lr.py`): the human route. One regression shared by all kanji predicts a coarse role
  (suffix, noun, verb, adjective, adverb, function word) from the neighbouring words' embeddings and classes; each
  reading is scored by how well its JMdict role fits. Only 45,622 of 107,527 tokens have a single role, and 2,336 are
  suffixes. Weight 0.25: −3 tokens (p=0.82); from 1.0 up it lost (−83 at 1.0, −416 at 2.0). 様 is unchanged at
  31/35 at every weight.
- **Word-sense choice in the lookup sheet.** Tatoeba's index marks the JMdict sense (`[01]`) on tokens, a free
  label. Rank a word's senses by the sentence the same way. First check whether the top gloss is still wrong
  often (not verified; the lemma tagging may have fixed the common cases).
- **Lemma choice for ambiguous surfaces.** 入り as noun vs 入る: let context vote, deterministically.
- **Example sentences.** Rank the lookup sheet's Tatoeba examples by similarity of their bag to the note's context.
- **Multiple-choice distractors.** Kioku/Learn/MultipleChoice/DistractorSelector.swift picks them; nearest
  neighbours by vector would replace DistractorRefinement and AppleIntelligenceDistractorClient. Read the selector
  first.
- **Review progression.** Use vector distance so near-synonyms are neither shown back to back nor left unpaired.
- **Register classifier** (RegisterClassifier.swift, ReadingRegisters.swift, import_reading_registers). Kept; it
  gives KWDLC 90.64 → 93.12% on web text. Try the note's bag vector as its input instead of character bigrams,
  and keep it only if it is at least as good on short notes.
- **Pitch accent for homographs.** `pitch_accent` is keyed by word and kana, not by sense, so one spelling with
  one reading cannot carry two accents. Only matters if such pairs turn out to exist in the data; check first.
- **Not doing:** "similar notes", topic grouping and semantic search over notes (declined).
