import Foundation

// Builds segmentation lattice edges by querying dictionary prefix matches at each text position.
nonisolated final class Segmenter: TextSegmenting, @unchecked Sendable {

    // var, not let: ContentView's startup sequence publishes a cheap PLACEHOLDER Segmenter
    // (empty trie) immediately so the UI has something non-optional to bind to, then swaps in
    // the real trie/deinflector once the slow dictionary load finishes — see reconfigure(...).
    // Any closure that captured a reference to this Segmenter instance before that swap (e.g.
    // a SwiftUI struct's implicit `self` capture inside a nested UIKit-bridged callback chain)
    // would otherwise be permanently stuck seeing an empty trie for the rest of the app's life,
    // since ContentView previously replaced the whole Segmenter object rather than updating it —
    // reconfigure() keeps this instance's IDENTITY stable so every existing reference (stale or
    // fresh) observes the same populated data once loading completes.
    // Not private (like the other three below): Segmenter+LemmaResolution.swift reads these.
    var trie: DictionaryTrie
    var deinflector: Deinflector?
    private let config: SegmenterConfig
    private let scoring: SegmenterScoring
    // Per-entry POS bitfields loaded from the dictionary; empty when built without metadata.
    var partOfSpeechByEntryID: [Int: UInt64]
    // Surface → unified frequency score (~0–7 Zipf-equivalent; higher = more common), derived from
    // jpdb_rank (and wordfreq Zipf when present). Two consumers:
    //   • edgeCost — the core statistical node cost of the global path (rare words cost more).
    //   • preferredLemmaScore — frequency tiebreak between equally-script-matched lemma candidates.
    // Empty when the segmenter is built without the surface-reading map (e.g., test fixtures); in
    // that case the scoring falls back to the script-only tiebreakers and a zero frequency term.
    var frequencyScoreBySurface: [String: Double]
    // Transition costs between adjacent word classes on a path; nil scores paths by word costs alone.
    var transitionTable: SegmenterTransitionTable?
    // Whether chosen segments are shown at word granularity: a particle cluster (には, ですか — see
    // ParticleClusters) or a form with a helper word glued on (飛び込んで|ゆく, 来て|くれる — see
    // Deinflector.helperWordOffsets) is shown as its words, and a と-taking adverb with its と
    // (ピッと — see adverbialToPrefix) as one. Always on in the app; the quality tests turn it off to
    // score against gold tokens that keep clusters whole.
    var splitsClusters = true
    // Set to true locally to print POS transition decisions during Viterbi runs.
    let shouldLogPOSTransitions = false
    // Shared set of characters that are always their own segment — single source of truth for
    // every segmentation path (main segmenter, preview, anything else that needs to agree on
    // where punctuation splits).
    static let boundaryCharacters: Set<Character> = [
        " ", "\t", "\n", "\r", "　",
        ".", ",", "!", "?", ";", ":",
        "。", "、", "！", "？", "・",
        "「", "」", "『", "』",
        "(", ")", "（", "）",
        "[", "]", "{", "}",
        "-", "—", "…", "，", "．"
    ]
    private var boundaryCharacters: Set<Character> { Self.boundaryCharacters }

    // Characters that can never begin a Japanese word and so must never begin a segment: small kana
    // (ya-row, a-row, wa, small ka/ke) in both hiragana and katakana, plus the prolonged sound mark
    // (ー / halfwidth ｰ). When the greedy walk strands one of these at a segment start it is absorbed
    // into the preceding segment. Small tsu (っ/ッ) is handled separately in the selection loop
    // because って/った are legitimate casual segment heads.
    static let neverInitialKana: Set<Character> = [
        "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ",
        "ァ", "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ",
        "ー", "ｰ"
    ]

    // Stores trie dependency used for prefix lookup when constructing lattices.
    init(
        trie: DictionaryTrie,
        deinflector: Deinflector? = nil,
        partOfSpeechByEntryID: [Int: UInt64] = [:],
        config: SegmenterConfig = SegmenterConfig(),
        scoring: SegmenterScoring = .default,
        frequencyScoreBySurface: [String: Double] = [:],
        transitionTable: SegmenterTransitionTable? = nil
    ) {
        self.trie = trie
        self.deinflector = deinflector
        self.partOfSpeechByEntryID = partOfSpeechByEntryID
        self.config = config
        self.scoring = scoring
        self.frequencyScoreBySurface = frequencyScoreBySurface
        self.transitionTable = transitionTable
    }

    // Builds the production segmenter for a loaded dictionary, fetching the cost model's frequency
    // map and loading its transition table itself. The app (ContentView) and the test harness (TestReadResources) both come through
    // here, so the two cannot be wired to different frequency sources — which is what once let the
    // tests pass on surface_frequency while the app still ran on the per-entry propagated ranks.
    // A store whose frequency table can't be read yields an empty map (every word unranked).
    convenience init(
        trie: DictionaryTrie,
        deinflector: Deinflector?,
        partOfSpeechByEntryID: [Int: UInt64],
        frequenciesFrom dictionaryStore: DictionaryStore?
    ) {
        self.init(
            trie: trie,
            deinflector: deinflector,
            partOfSpeechByEntryID: partOfSpeechByEntryID,
            frequencyScoreBySurface: (try? dictionaryStore?.fetchFrequencyScoreBySurface()) ?? [:],
            transitionTable: SegmenterTransitionTable.bundled()
        )
    }

    // Swaps in fully-loaded dictionary data while preserving this instance's identity — see the
    // property-group comment above for why identity stability matters more than a fresh init here.
    func reconfigure(
        trie: DictionaryTrie,
        deinflector: Deinflector?,
        partOfSpeechByEntryID: [Int: UInt64],
        frequencyScoreBySurface: [String: Double],
        transitionTable: SegmenterTransitionTable?
    ) {
        self.transitionTable = transitionTable
        self.trie = trie
        self.deinflector = deinflector
        self.partOfSpeechByEntryID = partOfSpeechByEntryID
        self.frequencyScoreBySurface = frequencyScoreBySurface
    }

    // Convenience for ContentView's startup sequence, which builds a brand-new Segmenter on a
    // background thread and needs to fold its data into the already-published placeholder
    // instance rather than replacing it — see the property-group comment above.
    func reconfigure(from other: Segmenter) {
        reconfigure(
            trie: other.trie,
            deinflector: other.deinflector,
            partOfSpeechByEntryID: other.partOfSpeechByEntryID,
            frequencyScoreBySurface: other.frequencyScoreBySurface,
            transitionTable: other.transitionTable
        )
    }

    // Generates all dictionary-backed lattice edges for every start position in the input text.
    func buildLattice(for text: String) -> [LatticeEdge] {
        var edges: [LatticeEdge] = []
        // Only the greedy walk needs the standalone-kana list: the path search prices stray single
        // kana out by frequency, and gating them costs it ん|だろう, に|お, 諸君|ら.
        let usesStandaloneKanaList = SegmenterSettings.usesGlobalLongestMatch == false

        var index = text.startIndex

        while index < text.endIndex {
            if boundaryCharacters.contains(text[index]) {
                let nextIndex = text.index(after: index)
                let boundarySurface = String(text[index..<nextIndex])
                edges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: boundarySurface
                    )
                )
                index = nextIndex
                continue
            }

            var keptMatches = 0
            // Whether any edge longer than one character starts here; see the fallback below.
            var keptMultiCharacterMatch = false

            if let numberEdge = numberRunEdge(in: text, startingAt: index) {
                edges.append(numberEdge)
                keptMatches += 1
            }

            if let latinEdge = latinRunEdge(in: text, startingAt: index) {
                edges.append(latinEdge)
                keptMatches += 1
                if text.distance(from: latinEdge.start, to: latinEdge.end) > 1 { keptMultiCharacterMatch = true }
            }

            var endIndex = index

            while endIndex < text.endIndex {
                let nextCharacter = text[endIndex]
                if isLineBreakCharacter(nextCharacter) {
                    break
                }

                endIndex = text.index(after: endIndex)
                let surfaceRange = index..<endIndex
                let characterLength = text.distance(from: surfaceRange.lowerBound, to: surfaceRange.upperBound)

                if characterLength > config.maxMatchLength {
                    break
                }

                let surface = String(text[surfaceRange])

                // A span that mixes hiragana and katakana is almost never one morpheme, and the
                // kana-normalizing deinflector would happily resolve such spans to real words
                // (ビロード+の→「ドの」→どの, ケンカ+もした→「カもした」→醸す). Two kinds are genuine and
                // get an edge; every other mixed span gets none.
                //
                // First: a katakana loanword noun tagged vs (キス "n,vs") directly followed by a
                // conjugated する (して, した, しない, …) — a compound verb JMdict never spells out as
                // a headword. See suruCompoundEdge for the admission checks; ビロード carries no vs
                // tag and the stray カ of ケンカ is not a trie noun, so neither bug reopens.
                if ScriptClassifier.mixesHiraganaAndKatakana(surface) {
                    if let katakanaPrefix = ScriptClassifier.leadingKatakanaPrefix(of: surface),
                       katakanaPrefix.count < surface.count,
                       isValidatedSuruNounPrefix(katakanaPrefix),
                       let edge = suruCompoundEdge(surface: surface, range: surfaceRange) {
                        edges.append(edge)
                        keptMatches += 1
                        keptMultiCharacterMatch = true
                        continue
                    }
                }

                var (lemmas, inflectionSteps) = resolvedTrieLemmasWithInflectionSteps(for: surface)

                // Second exception: a word that is itself WRITTEN across the two scripts — ウソつき,
                // 消しゴム, and katakana-stem verbs like サボった (→ サボる). What separates these from the
                // fusions above is the lemma: どの and 醸す are not written across a script switch, ウソつき
                // and サボる are, at the same place the surface switches. Only such lemmas are kept.
                if ScriptClassifier.mixesHiraganaAndKatakana(surface) {
                    lemmas = lemmas.filter { ScriptClassifier.sharesKanaScriptSwitch($0, with: surface) }
                    if lemmas.isEmpty { continue }
                }

                if lemmas.isEmpty == false {
                    // A single kana that can never begin a segment (ー, small kana) is never a word on
                    // its own even when the dictionary lists it; it joins the segment before it.
                    if surface.count == 1, Self.neverInitialKana.contains(surface.first!) {
                        continue
                    }
                    // Greedy only: bound single-kana morphemes (た、ら、etc.) are excluded; only standalone-valid kana pass.
                    if usesStandaloneKanaList, surface.count == 1, ScriptClassifier.isPureKana(surface),
                       !config.standaloneKana.contains(surface) {
                        continue
                    }
                    // Populate POS + dict flag: the path search classes each edge by its POS bits (TransitionClass).
                    // POS comes from the surface's own trie node, plus the POS of the lemma the edge is
                    // priced as (pricedReading) when that reading wins.
                    let posBits = trie.partOfSpeech(for: surface)
                    var edge = LatticeEdge(
                        start: surfaceRange.lowerBound,
                        end: surfaceRange.upperBound,
                        surface: surface
                    )
                    edge.partOfSpeech = posBits
                    edge.inflectionSteps = inflectionSteps
                    edge.isDictionaryMatch = true
                    // Frequency, step count and POS of whichever reading of the surface is cheaper.
                    let reading = pricedReading(of: surface, lemmas: lemmas, inflectionSteps: inflectionSteps)
                    edge.frequencyScore = reading.score
                    // A lone kana that is neither a function word with a transition class of its own
                    // (か, と, よ…) nor a counter (つ) is rarely a word in running text, however JPDB
                    // ranks it: ま is one gold token in 15,959 occurrences. Without this, ま|って beat
                    // 待って on a line of its own. See SegmenterScoring.loneKanaPenalty.
                    if surface.count == 1, ScriptClassifier.isPureKana(surface),
                       let lexical = transitionTable?.lexical, lexical.contains(surface) == false,
                       PartOfSpeech.isCounter(edge.partOfSpeech) == false,
                       edge.frequencyScore > 0 {
                        edge.frequencyScore = max(
                            SegmenterScoring.unrankedDictionaryScore,
                            edge.frequencyScore - SegmenterScoring.loneKanaPenalty
                        )
                    }
                    edge.inflectionSteps = reading.inflectionSteps
                    edge.partOfSpeech |= reading.lemmaPartOfSpeech
                    // Flag entries that bundle a known grammatical kana as their final char
                    // when the rest of the surface is its own dict entry — these are the rare
                    // "たいよ"-style bundles that need to lose to the compositional path.
                    if surface.count > 1, let lastChar = surface.last,
                       SegmenterScoring.grammaticalEndingKana.contains(lastChar) {
                        let prefix = String(surface.dropLast())
                        if trie.contains(prefix) {
                            edge.decomposesAtGrammaticalEnding = true
                        }
                    }
                    edges.append(edge)
                    keptMatches += 1
                    if characterLength > 1 { keptMultiCharacterMatch = true }
                }
            }

            // Ensures every character position has at least one outgoing edge.
            // Single-character fallback so the greedy walk lands on every position,
            // allowing dictionary words that start mid-unknown-run to be reached.
            // A katakana run whose first kana is also a one-character entry (リ of リュミエール, シ of
            // シェノン) still gets its whole-run edge, or an unknown loanword could only come out as
            // that kana plus the rest; the path search weighs the two on cost.
            let isKatakanaRunStart = ScriptClassifier.isPureKatakana(String(text[index]))
            if keptMatches == 0 || (keptMultiCharacterMatch == false && isKatakanaRunStart) {
                let fallbackRange = unknownFallbackRange(
                    in: text,
                    startingAt: index,
                    breakingAtStandaloneKana: usesStandaloneKanaList
                )
                var fallbackEdge = LatticeEdge(
                    start: fallbackRange.lowerBound,
                    end: fallbackRange.upperBound,
                    surface: String(text[fallbackRange])
                )
                // A one-kana run here would only duplicate the dictionary edge for that kana.
                let duplicatesSingleKanaMatch = keptMatches > 0 && text.index(after: index) == fallbackRange.upperBound
                if text.index(after: index) == fallbackRange.upperBound,
                   index > text.startIndex,
                   isSpanBreak(text[text.index(before: index)]) == false,
                   isBoundCharacter(at: index, in: text) {
                    fallbackEdge.isAbsorbedBoundCharacter = true
                }
                if duplicatesSingleKanaMatch == false {
                    edges.append(fallbackEdge)
                }
            }

            index = text.index(after: index)
        }

        return edges
    }

    // Prints lattice edges grouped by start position. Uses buildLattice as the single
    // source of truth so the output reflects exactly what the segmenter reasons over —
    // no duplicated traversal logic, no drift from kana filtering or maxMatchesPerPosition.
    func debugPrintLattice(for text: String) {
        let edges = buildLattice(for: text)

        var byStart: [Int: [LatticeEdge]] = [:]
        for edge in edges {
            let offset = text.distance(from: text.startIndex, to: edge.start)
            byStart[offset, default: []].append(edge)
        }

        AppLog.debug(.segmentation, "=== LATTICE (\(edges.count) edges) ===")
        for startOffset in byStart.keys.sorted() {
            AppLog.debug(.segmentation, "\(startOffset):")
            for edge in byStart[startOffset]!.sorted(by: { $0.surface < $1.surface }) {
                let endOffset = text.distance(from: text.startIndex, to: edge.end)
                let lemmas = resolvedTrieLemmas(for: edge.surface).sorted()
                if lemmas.isEmpty {
                    AppLog.debug(.segmentation, "  [\(startOffset),\(endOffset)) \(escapedForDebug(edge.surface))")
                } else {
                    for lemma in lemmas {
                        let summary = debugResolutionSummary(for: edge.surface, lemma: lemma)
                        AppLog.debug(.segmentation, "  [\(startOffset),\(endOffset)) \(escapedForDebug(edge.surface)) → \(escapedForDebug(lemma)) [\(summary)]")
                    }
                }
            }
        }
        AppLog.debug(.segmentation, "================")
    }

    // Builds a greedy segmentation by selecting the farthest-reaching edge at each text index.
    func longestMatchSegments(for text: String) -> [Range<String.Index>] {
        longestMatchEdges(for: text).map { edge in
            edge.start..<edge.end
        }
    }

    // Enumerates every valid segmentation path through the lattice DAG using memoized DFS.
    // Each returned path is an ordered edge list that exactly covers the full input string.
    // Complexity is bounded by the number of distinct paths, which can be exponential for long
    // ambiguous text — callers should apply a result cap for UI usage.
    func allSegmentationPaths(for text: String, limit: Int = 256) -> [[LatticeEdge]] {
        let edges = buildLattice(for: text)

        var edgesByStart: [String.Index: [LatticeEdge]] = [:]
        for edge in edges {
            edgesByStart[edge.start, default: []].append(edge)
        }

        var memo: [String.Index: [[LatticeEdge]]] = [:]

        // Recursively enumerates all edge paths from the given index to the end of the text.
        func paths(from index: String.Index) -> [[LatticeEdge]] {
            if index == text.endIndex {return [[]]}
            if let cached = memo[index] {return cached}
            var result: [[LatticeEdge]] = []
            for token in edgesByStart[index] ?? [] {
                let suffixes = paths(from: token.end)
                for suffix in suffixes {
                    result.append([token] + suffix)
                    if result.count >= limit {
                        memo[index] = result
                        return result
                    }
                }
            }
            memo[index] = result
            return result
        }

        return paths(from: text.startIndex)
    }

    // Produces both the full candidate lattice and the currently selected path for one text snapshot.
    // Path selection is global by default: the Viterbi DP picks the minimum-cost path over the whole
    // line, with node costs from SegmenterScoring.edgeCost. When the strategy setting is
    // localLongestMatch, the same lattice is instead walked greedily, longest edge first.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge]) {
        let latticeEdges = buildLattice(for: text)

        if SegmenterSettings.usesGlobalLongestMatch {
            let (annotatedEdges, path, _) = viterbiSelect(from: latticeEdges, in: text)
            // If Viterbi fails to terminate (no path reaches text.endIndex), fall through to greedy
            // so we never return a partial / empty segmentation. This keeps the flag safe to flip.
            if !path.isEmpty {
                return (latticeEdges: annotatedEdges, selectedEdges: splittingClusters(in: absorbingBoundCharacters(in: path, of: text), lattice: annotatedEdges, of: text))
            }
        }

        var edgesByStart: [String.Index: [LatticeEdge]] = [:]

        for edge in latticeEdges {
            edgesByStart[edge.start, default: []].append(edge)
        }

        var selectedEdges: [LatticeEdge] = []
        var index = text.startIndex

        while index < text.endIndex {
            if let candidates = edgesByStart[index] {
                // Sort candidates best-first so we can try alternates when the top choice strands a っ.
                let sorted = candidates.sorted { lhs, rhs in
                    compareEdgePriority(rhs, lhs, in: text)
                }
                // Pick the best candidate that does not leave a bare っ immediately after its end.
                // A lone っ is never a valid morpheme; finding one means the edge over-consumed.
                let chosen = sorted.first { edge in
                    let nextPos = edge.end
                    guard nextPos < text.endIndex else { return true }
                    let nextChar = text[nextPos]
                    // Reject if the character immediately following this edge is a small-tsu (っ/ッ)
                    // that has no dictionary candidate starting at that position — it would be stranded.
                    guard nextChar == "っ" || nextChar == "ッ" else { return true }
                    // A っ may only begin the next segment when a multi-char candidate starts there
                    // (e.g. った, って). Anything else — a lone っ edge, or no edge at all — means this
                    // edge over-consumed (e.g. もっとも out of もっともっと), so try the next candidate.
                    return edgesByStart[nextPos]?.contains { e in
                        text.distance(from: e.start, to: e.end) > 1
                    } ?? false
                } ?? sorted[0]
                selectedEdges.append(chosen)
                index = chosen.end
            } else {
                let nextIndex = text.index(after: index)
                let fallbackSurface = String(text[index..<nextIndex])
                selectedEdges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: fallbackSurface
                    )
                )
                index = nextIndex
            }

            // Absorb a bound character that can never begin a word into the segment just selected,
            // so no segment starts with an orphaned glyph. Two classes:
            //  • Small kana (ゃゅょ, ぁぃぅぇぉ, ゎ, ゕゖ + katakana) and the prolonged sound mark (ー):
            //    categorically never word-initial — always absorb.
            //  • Small tsu (っ/ッ): a sokuon, also bound, but って/った are legitimate casual segment
            //    heads — so absorb only when the tsu is NOT followed by kana (end-of-text / boundary).
            // A genuinely line-initial bound char (previous token is a boundary) is left alone.
            while index < text.endIndex,
                  let last = selectedEdges.last,
                  !(last.surface.count == 1 && isSpanBreak(last.surface.first!)) {
                let character = text[index]
                let isSmallTsu = (character == "っ" || character == "ッ")
                if isSmallTsu {
                    let afterTsu = text.index(after: index)
                    let followedByKana = afterTsu < text.endIndex
                        && isSpanBreak(text[afterTsu]) == false
                        && ScriptClassifier.isPureKana(String(text[afterTsu]))
                    if followedByKana { break }
                } else if Self.neverInitialKana.contains(character) == false {
                    break
                }
                let nextIndex = text.index(after: index)
                selectedEdges.removeLast()
                selectedEdges.append(
                    LatticeEdge(start: last.start, end: nextIndex, surface: String(text[last.start..<nextIndex]))
                )
                index = nextIndex
            }
        }

        return (latticeEdges: latticeEdges, selectedEdges: splittingClusters(in: selectedEdges, lattice: latticeEdges, of: text))
    }

    // Replaces each chosen segment made of several words with those words when splitsClusters is on:
    // a particle cluster (には → に|は) or a form with a helper word glued on (飛び込んでゆく →
    // 飛び込んで|ゆく, split where the chain to the segment's lemma says the helper starts). It runs
    // after path selection, so the option changes how finely a segment is shown and never which path
    // wins. A part takes the lattice's own edge for its span when there is one, so it carries the
    // same lemma and POS it would have had if the path had chosen it directly.
    private func splittingClusters(in path: [LatticeEdge], lattice: [LatticeEdge], of text: String) -> [LatticeEdge] {
        guard splitsClusters else { return path }

        var result: [LatticeEdge] = []
        result.reserveCapacity(path.count + 4)
        for edge in path {
            let parts = ParticleClusters.components[edge.surface] ?? helperWordParts(of: edge)
            guard let parts, parts.count > 1 else {
                result.append(edge)
                continue
            }
            var start = edge.start
            for part in parts {
                let end = text.index(start, offsetBy: part.count)
                if let existing = lattice.first(where: { $0.start == start && $0.end == end && $0.isDictionaryMatch }) {
                    result.append(existing)
                } else {
                    var piece = LatticeEdge(start: start, end: end, surface: part)
                    piece.partOfSpeech = trie.partOfSpeech(for: part)
                    piece.isDictionaryMatch = trie.contains(part)
                    piece.frequencyScore = frequencyScore(of: part)
                    result.append(piece)
                }
                start = end
            }
        }
        return mergingAdverbialTo(result)
    }

    // Joins a と-taking adverb and the と after it into one segment (ピッ|と → ピッと, see
    // adverbialToPrefix): together they are one adverb, and lookup resolves the pair to the adverb.
    private func mergingAdverbialTo(_ path: [LatticeEdge]) -> [LatticeEdge] {
        var result: [LatticeEdge] = []
        result.reserveCapacity(path.count)
        for edge in path {
            if edge.surface == "と", let previous = result.last, previous.end == edge.start,
               adverbialToPrefix(for: previous.surface + edge.surface) != nil {
                var merged = LatticeEdge(start: previous.start, end: edge.end, surface: previous.surface + edge.surface)
                merged.lemma = previous.surface
                merged.partOfSpeech = previous.partOfSpeech
                merged.isDictionaryMatch = true
                merged.frequencyScore = previous.frequencyScore
                result[result.count - 1] = merged
            } else {
                result.append(edge)
            }
        }
        return result
    }

    // The words of a conjugated segment with a helper word glued on (飛び込んでいった → 飛び込んで,
    // いった), following the chain to the lemma lookup shows for it; nil when it has none.
    private func helperWordParts(of edge: LatticeEdge) -> [String]? {
        guard edge.isDictionaryMatch, edge.inflectionSteps > 0, let deinflector,
              let lemma = preferredLemma(for: edge.surface) else { return nil }
        let offsets = deinflector.helperWordOffsets(in: edge.surface, lemma: lemma)
        guard offsets.isEmpty == false else { return nil }
        let characters = Array(edge.surface)
        let bounds = [0] + offsets + [characters.count]
        return zip(bounds, bounds.dropFirst()).map { String(characters[$0..<$1]) }
    }

    // Folds bound characters at the head of a selected edge into the segment before it, so no
    // segment of the global path starts with a glyph that can never begin a word. Same two classes
    // the local walk absorbs inline: small kana and the prolonged sound mark always; small tsu only
    // when it is not followed by kana (って/った are legitimate segment heads). A bound character
    // with no preceding segment, or one directly after a boundary character, is left alone.
    private func absorbingBoundCharacters(in path: [LatticeEdge], of text: String) -> [LatticeEdge] {
        var result: [LatticeEdge] = []
        result.reserveCapacity(path.count)

        for edge in path {
            var start = edge.start
            // A dictionary word keeps its first character: ヶ月 begins with a "never-initial" kana.
            while start < edge.end, edge.isDictionaryMatch == false,
                  let last = result.last,
                  !(last.surface.count == 1 && isSpanBreak(last.surface.first!)),
                  isBoundCharacter(at: start, in: text) {
                let next = text.index(after: start)
                result[result.count - 1] = LatticeEdge(
                    start: last.start,
                    end: next,
                    surface: String(text[last.start..<next])
                )
                start = next
            }

            if start == edge.start {
                result.append(edge)
            } else if start < edge.end {
                result.append(LatticeEdge(start: start, end: edge.end, surface: String(text[start..<edge.end])))
            }
        }

        return result
    }

    // True when the character at this index can never begin a segment: a never-initial kana, or a
    // small tsu that is not followed by kana.
    private func isBoundCharacter(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if Self.neverInitialKana.contains(character) { return true }
        guard character == "っ" || character == "ッ" else { return false }
        let afterTsu = text.index(after: index)
        let followedByKana = afterTsu < text.endIndex
            && isSpanBreak(text[afterTsu]) == false
            && ScriptClassifier.isPureKana(String(text[afterTsu]))
        return followedByKana == false
    }

    // Builds a greedy segmentation edge list so downstream features can use chosen surface/lemma references.
    func longestMatchEdges(for text: String) -> [LatticeEdge] {
        longestMatchResult(for: text).selectedEdges
    }

    // Breaks longest-match ties by preferring higher-quality lemma resolution for the same span.
    // Pure-kana exact trie matches receive a length bonus so deinflection-only noise candidates
    // (e.g. もき → もく) don't block adjacent real words (e.g. きっと) by winning on raw length.
    private func compareEdgePriority(_ lhs: LatticeEdge, _ rhs: LatticeEdge, in text: String) -> Bool {
        // Demotion dominates every other discriminator: a surface in the SegmentationDemotions
        // denylist (のか, のす, …) sinks below any non-demoted candidate starting at the same
        // position, regardless of length. This is the greedy analog of edgeCost's soft penalty —
        // a demoted surface is still chosen when it is the only candidate here. Returning true
        // means lhs ranks *lower* than rhs, so lhs loses iff lhs is the demoted one.
        let lhsDemoted = SegmentationDemotions.contains(lhs.surface)
        let rhsDemoted = SegmentationDemotions.contains(rhs.surface)
        if lhsDemoted != rhsDemoted {
            return lhsDemoted
        }

        let lhsLength = text.distance(from: lhs.start, to: lhs.end)
        let rhsLength = text.distance(from: rhs.start, to: rhs.end)

        // Give single-char pure-kana particles a small bonus so single-char deinflection-only kana
        // edges (e.g. もき → もく) can't beat them, while still allowing genuinely longer deinflected
        // forms (e.g. つないだ→つなぐ over つな, かなえて→かなえる over かなえ) to win on raw length.
        // The bonus is intentionally restricted to single-char kana: applying it to multi-char stems
        // like かなえ causes them to tie with — and then beat — longer deinflected forms like かなえて.
        let lhsAdjustedLength = lhsLength + singleCharKanaExactBonus(for: lhs.surface)
        let rhsAdjustedLength = rhsLength + singleCharKanaExactBonus(for: rhs.surface)
        if lhsAdjustedLength != rhsAdjustedLength {
            return lhsAdjustedLength < rhsAdjustedLength
        }

        let lhsDerivedLemma = preferredLemma(for: lhs.surface) ?? lhs.surface
        let rhsDerivedLemma = preferredLemma(for: rhs.surface) ?? rhs.surface
        let lhsLemmaScore = preferredLemmaScore(for: lhsDerivedLemma, sourceSurface: lhs.surface)
        let rhsLemmaScore = preferredLemmaScore(for: rhsDerivedLemma, sourceSurface: rhs.surface)
        if lhsLemmaScore != rhsLemmaScore {
            return lhsLemmaScore < rhsLemmaScore
        }

        let lhsFrequencyScore = preferredLemmaFrequencyScore(for: lhsDerivedLemma)
        let rhsFrequencyScore = preferredLemmaFrequencyScore(for: rhsDerivedLemma)
        if lhsFrequencyScore != rhsFrequencyScore {
            return lhsFrequencyScore < rhsFrequencyScore
        }

        if lhsDerivedLemma.count != rhsDerivedLemma.count {
            return lhsDerivedLemma.count < rhsDerivedLemma.count
        }

        return lhsDerivedLemma > rhsDerivedLemma
    }

    // Determines how far an unknown segment should extend by grouping contiguous same-script runs.
    private func unknownFallbackRange(
        in text: String,
        startingAt index: String.Index,
        breakingAtStandaloneKana: Bool
    ) -> Range<String.Index> {
        let firstCharacter = text[index]
        guard let group = ScriptClassifier.unknownGrouping(for: firstCharacter) else {
            let nextIndex = text.index(after: index)
            return index..<nextIndex
        }

        var currentIndex = text.index(after: index)
        var groupedLength = 1

        while currentIndex < text.endIndex && groupedLength < config.maxMatchLength {
            let character = text[currentIndex]
            if isSpanBreak(character) { break }

            if ScriptClassifier.unknownGrouping(for: character) != group { break }

            // Greedy only: stop before standalone particles so they get their own edge rather than being
            // absorbed into an unknown run (e.g. だ must not consume ね when ね is a standalone particle).
            if breakingAtStandaloneKana, config.standaloneKana.contains(String(character)) { break }

            currentIndex = text.index(after: currentIndex)
            groupedLength += 1
        }

        return index..<currentIndex
    }

    // Applies unknown penalty to non-dictionary non-boundary edges so punctuation separators are not over-penalized.
    private func shouldApplyUnknownSegmentPenalty(_ edge: LatticeEdge) -> Bool {
        if isDictionaryEdge(edge) { return false }

        for character in edge.surface {
            if !boundaryCharacters.contains(character) { return true }
        }

        return false
    }

    // Determines whether an edge is dictionary-backed without database access.
    private func isDictionaryEdge(_ edge: LatticeEdge) -> Bool {
        resolvesSurface(edge.surface)
    }

    // Prints greedy longest-match segments line-by-line for segmenter debugging.
    func debugPrintSegments(for text: String) {
        let segments = longestMatchSegments(for: text)

        for segment in segments {
            AppLog.debug(.segmentation, String(text[segment]))
        }
    }

    // Detects Unicode newline characters so scanned spans never cross line boundaries.
    private func isLineBreakCharacter(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                return true
            }
        }

        return false
    }

    // True for any character that ends a scan span: a configured boundary character or a
    // Unicode line break. Centralizes the boundary-or-newline test the span scanners share.
    private func isSpanBreak(_ character: Character) -> Bool {
        boundaryCharacters.contains(character) || isLineBreakCharacter(character)
    }

    // +1 length bonus for a single-char pure-kana surface that exists verbatim in the trie,
    // so single-char deinflection-only kana edges can't beat genuine single-char particles.
    // See compareEdgePriority for why the bonus is restricted to single-char kana.
    private func singleCharKanaExactBonus(for surface: String) -> Int {
        (surface.count == 1 && ScriptClassifier.isPureKana(surface) && trie.contains(surface)) ? 1 : 0
    }

    // Escapes control line-break characters for stable single-line debug output.
    private func escapedForDebug(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
