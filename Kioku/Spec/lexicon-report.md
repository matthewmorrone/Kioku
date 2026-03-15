
**Scope And Evidence**
Audit covered the implementations in Lexicon.swift, SQLite access in DictionaryStore.swift, reader loop code in ReadView+Furigana.swift, segmentation pipeline in Segmenter.swift, startup loading in ContentView.swift, and DB index creation in generate_db.py.

**Call Graph (Target Methods)**
reading(surface) -> lemma(surface) -> deinflectionPaths(for:) + segmenter admission  
reading(surface) -> readingForLemma -> lookupLexeme(lemma, nil) -> lookupEntries(for:) -> DictionaryStore.lookup(...)  
normalize(surface) -> lemma(surface) + readingForLemma(...)  
inflectionInfo(surface) -> lemma(surface) + inflectionChain(surface,targetLemma)  
resolve(surface) -> rebuildLatticeGraph(for:) + normalize(surface) + lookupLexeme(...) + inflectionChain(...)  
forms/senses/primaryReading/displayForm/matchedForm/kanjiCharacters -> lexeme(id) or forms(lexemeId)  
latticeNeighbors/nodeComponents -> in-memory lattice maps (nodeComponents also calls inflectionChain)  
expandInflection(lemma) -> loops rules -> lemma(surface) repeatedly  
inflectionChain(surface) -> lemma(surface) + deinflectionPaths(for:)

**Hot Path Reality (Per-Token While Reading Text)**
Current per-token reading loop uses in-memory maps and trie logic, not Lexicon methods:
- Furigana loop uses readingForSegment + readingBySurface/readingCandidatesBySurface in ReadView+Furigana.swift
- Segmentation uses trie/deinflector in Segmenter.swift

Lexicon is injected into ReadView but not consumed in production call sites (only tests reference these APIs), see ReadView.swift and LexiconTests.swift.

**Per-Method Audit Table**
| Method | SQLite? | Query/Data Source Touched | On Reader Hot Path? | Complexity | Performance Flags |
|---|---|---|---|---|---|
| reading(surface) | Indirect | readingBySurface map; may call DictionaryStore via lookupLexeme | No (currently unused in reader loop) | Best O(1), worst dominated by lemma + DB fallback | Recomputes deinflection work via downstream calls |
| lemma(surface) | Indirect | deinflectionPaths + Segmenter.resolvesSurface/preferredLemma (trie/deinflector in-memory) | No | O(R * state space) + sort | Expensive recomputation, allocates path graph every call |
| normalize(surface) | Indirect | lemma + readingForLemma; may trigger DB via lookupLexeme | No | O(L * readingForLemma) | Repeats lemma/deinflection work |
| inflectionInfo(surface) | Indirect | lemma + inflectionChain | No | O(lemma + chain selection) | Duplicates deinflection traversal |
| lookupLexeme(lemma, reading) | Yes | DictionaryStore.lookup -> fetchMatchedEntries + per-entry hydration | No | O(DB + entries) | DB-backed; no memoization of repeated lemma lookups |
| resolve(surface) | Indirect (often yes) | rebuildLatticeGraph + normalize + lookupLexeme + inflectionChain | No | O(E^2) lattice adjacency + candidate loops + DB | Recomputes chain/paths; lattice rebuild each call |
| lexeme(id) | Yes | DictionaryStore.lookupEntry (header + forms + senses) | No | O(1) DB roundtrips | Fixed multi-query fetch per call |
| forms(lexemeId) | Indirect (yes) | lexeme(id) result | No | O(K + A) + lexeme fetch | Re-fetches whole entry if caller already has it |
| senses(lexemeId) | Indirect (yes) | lexeme(id) result | No | O(total glosses) + lexeme fetch | Same redundant entry fetch pattern |
| primaryReading(lexemeId) | Indirect (yes) | lexeme(id) result | No | O(1) + lexeme fetch | Redundant fetch for single field |
| displayForm(lexemeId) | Indirect (yes) | forms + ScriptClassifier.containsKanji | No | O(forms) + lexeme fetch | Cascades redundant fetches |
| matchedForm(surface, lexemeId) | Indirect (yes) | forms + lemma + displayForm | No | O(forms + lemmas) | Can trigger expensive lemma path after forms fetch |
| containsKanji(text) | No | ScriptClassifier scalar scan | No | O(n) | No major issue |
| isKana(text) | No | ScriptClassifier scalar scan | No | O(n) | No major issue |
| kanjiCharacters(lexemeId) | Indirect (yes) | forms + ScriptClassifier.containsKanji | No | O(total chars in forms) + lexeme fetch | Another redundant fetch chain |
| latticeNeighbors(nodeId,distance) | No | latticeAdjacencyByNodeID map | No | O(V+E) within distance frontier | Pure in-memory BFS |
| nodeComponents(nodeId) | Indirect | latticeNodesByID + inflectionChain | No | O(chain generation) | Inflection recomputation each call |
| expandInflection(lemma) | Indirect (high risk) | loops labeledRules and calls lemma inside loop | No | Very high; roughly branching BFS * rules * lemma cost | N+1 pattern; can explode in calls/work |
| inflectionChain(surface) | Indirect | lemma + deinflectionPaths | No | O(R * state space) | Recomputes paths not memoized |

R = rule count, E = lattice edge count, L = admitted lemmas.

**SQLite Findings (Direct Answers To Goals)**
1. Methods with direct SQLite calls:
- lookupLexeme(lemma, reading) via DictionaryStore.lookup in Lexicon.swift
- lexeme(id) via DictionaryStore.lookupEntry in Lexicon.swift

1. Methods with indirect SQLite calls:
- reading, lemma, normalize, inflectionInfo, resolve, forms, senses, primaryReading, displayForm, matchedForm, kanjiCharacters, nodeComponents, expandInflection, inflectionChain (through lookupLexeme or lexeme paths)

1. SQLite in current per-token reader hot path:
- No, not through these methods. Reader loop uses preloaded maps and trie/deinflector in memory in ReadView+Furigana.swift and Segmenter.swift.

**Structural Issues**
- Dictionary lookups inside loops:
  - DictionaryStore.lookupEntries loops surfaces then entries with per-entry fetches in DictionaryStore.swift
  - expandInflection calls lemma inside rule loop in Lexicon.swift
- Repeated SQL statement preparation:
  - prepare/finalize per call pattern in DictionaryStore.swift
- Prepared statement reuse:
  - Not implemented; no statement cache layer
- Missing/weak indexes:
  - Existing indexes are created in generate_db.py
  - Likely beneficial composites are missing for common predicates/orderings:
    - surface_lookup(surface, entry_id)
    - kana_forms(text, entry_id)
    - kanji(text, entry_id)
    - senses(entry_id, order_index)
- JSON/rule loading repetition:
  - Not repeated per lookup; loaded at startup
  - But deinflection JSON is loaded twice (Deinflector and Lexicon) in ContentView.swift and ContentView.swift
- Regex/tokenizer object churn:
  - No regex-heavy path found in audited methods/files

**Large Allocation/Recompute Check (Requested)**
- reading, lemma, normalize, resolve do repeated recomputation of deinflection path graphs (especially deinflectionPaths), and create fresh arrays/dictionaries each call in Lexicon.swift.
- resolve also rebuilds lattice node/adjacency maps each call in Lexicon.swift, including O(E^2) adjacency construction.
- These are deterministic and good candidates for memoization keyed by surface/text snapshot.

**Methods To Move Toward In-Memory Indexes/Caches**
- High priority:
  - deinflectionPaths(for:) result cache (surface-keyed)
  - lookupLexeme(lemma, reading) short-lived memo cache
  - lexeme(id) entry cache
- Medium priority:
  - forms/senses/primaryReading/displayForm/kanjiCharacters should share one fetched entry object
  - resolve(surface) cache lattice graph by exact text snapshot
- Low/one-time:
  - unify deinflection rule loading so Lexicon and Deinflector share one parsed rule set

**Specific Refactoring Recommendations (No Code Changes Made)**
1. Add a memoization layer in Lexicon for deinflectionPaths(for:) and optionally inflectionChain selections.
2. Rewrite expandInflection to avoid lemma(...) inside the per-rule loop; use cheaper admission checks first, then validate survivors.
3. Add an entry-level cache in Lexicon for lexeme(id), and refactor forms/senses/primaryReading/displayForm/kanjiCharacters to consume that cached entry.
4. Add prepared-statement caching in DictionaryStore for the hottest SQL statements, or keep prepared statements alive per connection.
5. Add composite indexes aligned with actual WHERE/JOIN/ORDER BY patterns listed above.
6. If Lexicon APIs become reader-hot-path later, precompute lemma->reading and surface->normalized candidates for active text snapshots.

No files were modified.
