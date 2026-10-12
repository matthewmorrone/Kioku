# Known segmentation errors

Places where Kioku's segmentation is verifiably wrong, checked by hand against JMdict (2026-10-11,
held2k and a 15-case kana2k sample, segmenter at d2943c30). Delete an entry once a run shows it fixed.
Each line: Kioku's cut → the right cut, then the sentence (kana2k: the kanji original it was made from).

Not listed: cut-throughs that are only convention differences with the gold data. In these, Kioku's
piece is itself a JMdict suffix or expression used as such (２|回目, 知らない|振りをしています, 冷め|ないうちに,
足りない|っていう, 理性|の|タガがはずれる, 名状|すべからず). `score.py` still counts those as "error", so its
error count overstates the real ones (held2k: 15 reported, 9 real).

## held2k

- ６|月末 → ６月|末 — ６月末に参加者を募ったら…
- 望|まざる → 望ま|ざる — 自分が望むと望まざるとにかかわらず
- 中|日間 → 中日|間 — 中日間は本当にお互いを知り合うところまでは到達していない。
- オート|ロックする → オートロック|する — ドアを閉めたらオートロックするということはありません。
- どう|やらない → どうやら|ない — 資質は、どうやらないようだ。
- パシ|ら|されなきゃ → パシらされ|なきゃ — ジュース買う為にパシらされなきゃなんないんだか
- ５|日間 → ５日|間 — このオファーは５日間有効です。 (JMdict's 日間 is only "daytime")
- ブチキレ|ないほう → ブチキレない|ほう — ブチキレないほうがおかしい。 (ないほう resolves to 内包)
- 新年|度に|は → 新|年度|には — 零細小売店などは新年度には利益を上げるでしょう。

## kana2k (sample of 15 of its 106 "error" straddles; the rest are unaudited)

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

## How to find more

```bash
cd scripts/segmentation-eval   # after cli/build.sh and unpack-data.py
./work/segcli run < work/data/held2k.txt > work/held2k.out
python3 score.py work/data/held2k.jsonl work/held2k.out --examples 100 --errors-only
```
Then judge each "[error]" line against JMdict before adding it here.
