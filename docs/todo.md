# Todo

## Segmentation & Lookup

- [ ] LLM correction of segmentation/readings
- [ ] Halfwidth katakana normalization in lookup (ｱｲｳｴｵ → アイウエオ)
- [ ] Use frequency data to influence segmentation path selection
- [ ] Make "custom" last in list for readings
- [ ] Global reading mode should apply to alternative and custom readings

### Known segmentation failures

1. つないだ — segmented as つな|いだ, should be one segment (past tense of つなぐ)
2. まけない — segmented as まけ|ない, should be one segment (negative of まける)
3. その度 — segmented as その|度, should be one segment
4. 消してくれる — showing wrong reading しゅう, should be けしてくれる (from 消す)
5. 抱かれ — missing readings, should have いだかれ, だかれ, うだかれ
6. トキメク — segmented as トキ|メク, should be one segment (ときめく)
7. 済まれないで — not recognized at all
8. 月色 — should have reading つきいろ
9. ショーブかけましょ — still broken despite ー expansion fix
10. しょげちゃうんだ — unrecognized segment
11. プレイヤーズ — needs to be added to extras.json
12. ティアーズ — needs to be added to extras.json
13. ちゃいのん — not recognized
14. かなえて shows up as かなえ|て

## Read View

- [ ] Prevent scrolling all the way down in view mode
- [ ] Add in debug controls (highlight lines and envelopes)
- [ ] Import Whisper JSON `word_segments` into subtitle cues for word-level timing
- [ ] Note-level TTS: play/pause, rate and voice controls, spoken-range highlighting
- [ ] Add manual/custom word creation and editing

## Words & Dictionary

- [ ] Filter and sort saved words
- [ ] Add personal note to saved words
- [ ] CSV import: flexible parsing
- [ ] Add manual/custom word creation and editing

## Settings

- [ ] Adjust ruby typography settings (spacing, padding)
- [ ] Default to Japanese IME where appropriate
- [ ] Word-of-the-day: enable, set notification time, test notification
- [ ] Clipboard behavior settings
- [ ] Diagnostics toggles
