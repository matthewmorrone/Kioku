# Segmentation / Lookup Failures

Tracked list of segmenter / lookup cases that were broken at some point. As cases
get fixed they're moved to characterization tests in `KiokuTests/` and removed
from this list — the goal is to keep this short and current, not historical.

Last triaged: 2026-05-23 (against `dictionary.sqlite` regenerated from JMdict 3.6.2).

## Currently broken

- **済まれないで** — not recognized; no full-span edge. Likely needs a deinflection
  rule for the passive + negative + で linking chain on 済む.
- **ショーブかけましょ** — full string not segmented as one word; mixed-script
  loanword + native verb compound. The ー expansion fix from earlier didn't reach
  this case.
- **ちゃいのん** — not recognized; possibly a dialectal / casual form that's not
  in the bundled lexicon.

## Open reading-specific issues (not segmentation; lookups parse OK)

These cases segment correctly but produce the wrong surface reading. They're
listed here as a reminder rather than tracked elsewhere; a follow-up probe
through `surfaceReadingData` would be needed to confirm whether each is still
broken after the recent kana-form-ordering and lemma-scoring fixes.

- **消してくれる** — was showing reading しゅう instead of けして (from 消す).
  Segmentation + lemma now resolves to 消す; reading needs re-verification.
- **抱かれ** — was missing readings いだかれ / だかれ / うだかれ. Lemma resolves
  to 抱く; reading set needs re-verification.
- **月色** — should have reading つきいろ. Lemma resolves to 月色; reading needs
  re-verification.

## Resolved (pinned as characterization tests)

Cases that previously failed and now pass. See
`KiokuTests/SegmentationKnownGoodTests.swift` for the locked-in behavior.

- つないだ → one segment, lemma つなぐ
- まけない → one segment, lemma まける
- その度 → one segment, lemma その度
- トキメク → one segment, lemma ときめく (katakana → kana iteration via expansion)
- しょげちゃうんだ → one segment, lemma しょげる
- かなえて → one segment, lemma かなえる
- プレイヤーズ → one segment, recognized via extras.json
- ティアーズ → one segment, recognized via extras.json
