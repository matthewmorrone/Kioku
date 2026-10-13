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
