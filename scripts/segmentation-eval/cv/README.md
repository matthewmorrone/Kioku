# Reading-choice cross-validation

Offline harness for judging a change to how furigana picks a kanji run's reading (`ReadingContextTable`),
on Tatoeba's counted gold readings (~107k, ~49k of them kanji with 2+ readings). Gold segmentation, no
Apple vote, no phrase table: it isolates the context model. Decide on discordant tokens and the sign test,
not on held2k/fresh5k moves of a few tokens.

```
tokens.py   <jpn_indices.csv> <dictionary.sqlite> <segcli> <work>   # ~4 min: segcli count + cache (tokens.pkl)
vectors.py  <cc.ja.300.vec.gz> <work>/tokens.pkl <work>/vectors.npz  # ~1.5 min: keeps only the cache's words
cv.py       <work> [vectors.npz] [radius]                          # ~2.5 min: 10 contiguous folds, tables
```

```
lr.py       <work> <vectors.npz> [C]                               # ~3.5 min: per-kanji logistic regression on embeddings
```

`common.py` holds the counts and the two scores the app uses. `meaning_ambiguous` is derived from the
dictionary: kanji runs whose common readings (10+ counted) belong to different JMdict entries.
Tokens beside a numeral Tatoeba's index dropped (三人 → BOUNDARY 人) are reported apart.

Pretrained vectors: fastText `cc.ja.300` (Facebook, CC BY-SA 3.0), fetched to a temporary folder and deleted
after `vectors.py` cut it down.
