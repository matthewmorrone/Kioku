# Viterbi Segmentation — Removed

This documents the Viterbi-based segmentation path that was built into `Segmenter.swift` and subsequently removed in favor of delegating to AzooKeyKanaKanjiConverter.

---

## What it was

A minimum-cost dynamic programming segmentation algorithm operating over the lattice built by `buildLattice(for:)`. Instead of greedily picking the longest match at each position, it scored every possible path through the lattice and returned the globally optimal one.

### Node cost (`nodeCost`)

Each lattice edge was assigned a base cost:

- Dictionary word: cost 1
- Unknown (single-character fallback): cost 5
- Short-token penalty: +10 for length 1, +3 for length 2
- Length bonus: subtract character length (rewards longer matches)

### Transition cost (`transitionCost`)

Adjacent edges were penalized based on coarse inferred POS:

- Noun → particle: 0 (common, free)
- Particle → verb: 0 (common, free)
- Noun → noun: 3 (compound noun, moderate cost)
- Verb → verb: 3 (verb chain, moderate cost)
- Hiragana-only token following a kanji-ending token: +8 (likely okurigana bleed — discouraged)
- Default: 1

POS was inferred from surface/lemma heuristics: known particles by surface, verbs by lemma-ending (る/う/く/ぐ/す/つ/ぬ/ぶ/む), adjectives by い-ending, everything else as noun.

### Trie change

`DictionaryTrie` had a `prefixScan(in:startingAt:maxLength:)` method that returned both matched ranges and the farthest index reached during trie traversal. This was used to bound the deinflection fallback span. It was collapsed back into `prefixMatches(in:startingAt:)` when Viterbi was removed.

### Editor integration

`RichTextEditor` received `segmentRanges: [Range<String.Index>]` and rendered segments in alternating blue/red to visualize tokenization. This was removed along with the `refreshSegmentation()` call in `ReadView`.

---

## Why it was removed

AzooKeyKanaKanjiConverter provides a production-quality lattice segmenter with a full unigram language model trained on real Japanese corpora. The internal Viterbi implementation used hand-tuned integer costs and a five-category POS heuristic — it couldn't compete in quality and added significant complexity.

The internal `Segmenter` is now a lightweight fallback used only when AzooKey is unavailable or for specific lookup-expansion tasks. Greedy longest-match is sufficient for that role.

---

## If Viterbi is revisited

The lattice infrastructure (`buildLattice`, `LatticeEdge`, `DictionaryTrie`) is intact. `LatticeEdge` would need `pos` and `cost` fields restored, and `prefixScan` would need to return the farthest-scanned index for correct deinflection span bounding. The transition cost table should be replaced with a proper bigram or unigram model rather than hand-tuned integers.
