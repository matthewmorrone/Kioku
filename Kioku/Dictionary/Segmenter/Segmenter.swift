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
    // Set to true locally to print POS transition decisions during Viterbi runs.
    private let shouldLogPOSTransitions = false
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
                    // Greedy only: bound single-kana morphemes (た、ら、etc.) are excluded; only standalone-valid kana pass.
                    if usesStandaloneKanaList, surface.count == 1, ScriptClassifier.isPureKana(surface),
                       !config.standaloneKana.contains(surface) {
                        continue
                    }
                    // Populate POS + dict flag: the path search classes each edge by its POS bits (TransitionClass).
                    // POS comes from the surface's own trie node first; falls back to the union of
                    // POS bits across resolved lemmas when the surface is a deinflected form whose
                    // trie node isn't tagged directly.
                    var posBits = trie.partOfSpeech(for: surface)
                    if posBits == 0 {
                        for lemma in lemmas { posBits |= trie.partOfSpeech(for: lemma) }
                    }
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
                    // Direct surface lookup for IPADic context IDs (populated at dict-build time).
                    // For deinflected forms whose surface isn't tagged, fall through to the lemma's
                    // IDs — the resolved lemma is what tells us which IPADic slot the surface
                    // belongs in (e.g. 会い → 会う → verb-stem-godan IDs).
                    if let directIDs = trie.ipadicContextIDs(for: surface) {
                        edge.ipadicLeftID = directIDs.left
                        edge.ipadicRightID = directIDs.right
                    } else {
                        for lemma in lemmas {
                            if let lemmaIDs = trie.ipadicContextIDs(for: lemma) {
                                edge.ipadicLeftID = lemmaIDs.left
                                edge.ipadicRightID = lemmaIDs.right
                                break
                            }
                        }
                    }
                    edges.append(edge)
                    keptMatches += 1
                }
            }

            // Ensures every character position has at least one outgoing edge.
            // Single-character fallback so the greedy walk lands on every position,
            // allowing dictionary words that start mid-unknown-run to be reached.
            if keptMatches == 0 {
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
                if text.index(after: index) == fallbackRange.upperBound,
                   index > text.startIndex,
                   isSpanBreak(text[text.index(before: index)]) == false,
                   isBoundCharacter(at: index, in: text) {
                    fallbackEdge.isAbsorbedBoundCharacter = true
                }
                edges.append(fallbackEdge)
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
            let (annotatedEdges, path) = viterbiSelect(from: latticeEdges, in: text)
            // If Viterbi fails to terminate (no path reaches text.endIndex), fall through to greedy
            // so we never return a partial / empty segmentation. This keeps the flag safe to flip.
            if !path.isEmpty {
                return (latticeEdges: annotatedEdges, selectedEdges: splittingParticleClusters(in: absorbingBoundCharacters(in: path, of: text), lattice: annotatedEdges, of: text))
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

        return (latticeEdges: latticeEdges, selectedEdges: splittingParticleClusters(in: selectedEdges, lattice: latticeEdges, of: text))
    }

    // Replaces each chosen particle-cluster entry (には, ですか — see ParticleClusters) with its parts
    // when SegmenterSettings.splitsParticleClusters is on. It runs after path selection, so the
    // option changes how finely a cluster is shown and never which path wins. A part takes the
    // lattice's own edge for its span when there is one, so it carries the same lemma and POS it
    // would have had if the path had chosen it directly.
    private func splittingParticleClusters(in path: [LatticeEdge], lattice: [LatticeEdge], of text: String) -> [LatticeEdge] {
        guard SegmenterSettings.splitsParticleClusters,
              path.contains(where: { ParticleClusters.components[$0.surface] != nil }) else { return path }

        var result: [LatticeEdge] = []
        result.reserveCapacity(path.count + 4)
        for edge in path {
            guard let parts = ParticleClusters.components[edge.surface] else {
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
        return result
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
            while start < edge.end,
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

    // MARK: - Viterbi

    // Selects the minimum-cost lattice path using Viterbi DP: word costs plus class-pair transition costs.
    // Wired into longestMatchResult behind SegmenterSettings.usesGlobalLongestMatch; this entry
    // point remains available for direct callers (diagnostics, tests).
    func viterbiBestPath(for text: String) -> [LatticeEdge] {
        let edges = buildLattice(for: text)
        return viterbiSelect(from: edges, in: text).path
    }

    // Runs Viterbi search over an already-built lattice. Returns the edges (annotated in place with
    // per-edge score / predecessor metadata for the diagnostic overlay) and the chosen path.
    // Pulled out of viterbiBestPath so longestMatchResult can share its lattice instead of rebuilding.
    private func viterbiSelect(from inputEdges: [LatticeEdge], in text: String) -> (edges: [LatticeEdge], path: [LatticeEdge]) {
        var edges = inputEdges
        guard !edges.isEmpty else { return (edges: [], path: []) }

        var edgesByEnd: [String.Index: [Int]] = [:]
        for (i, edge) in edges.enumerated() { edgesByEnd[edge.end, default: []].append(i) }

        // Precompute character offsets for every edge endpoint once. String.distance is O(n) in
        // grapheme clusters, and calling it from inside a sort comparator turns Viterbi setup into
        // O(E log E · N) string traversal — large enough on real notes to trigger the iOS watchdog
        // and crash the app to home screen. Building offset arrays via a single index walk is O(N+E).
        var indexToCharOffset: [String.Index: Int] = [:]
        indexToCharOffset.reserveCapacity(text.count + 1)
        var walkIndex = text.startIndex
        var walkOffset = 0
        indexToCharOffset[walkIndex] = walkOffset
        while walkIndex < text.endIndex {
            walkIndex = text.index(after: walkIndex)
            walkOffset += 1
            indexToCharOffset[walkIndex] = walkOffset
        }

        let startOffsets = edges.map { indexToCharOffset[$0.start] ?? 0 }
        let endOffsets = edges.map { indexToCharOffset[$0.end] ?? 0 }

        let sortedIndices = edges.indices.sorted { li, ri in
            let le = endOffsets[li]
            let re = endOffsets[ri]
            if le == re { return startOffsets[li] < startOffsets[ri] }
            return le < re
        }

        // Each edge's transition class, resolved once; a bound character is folded into the segment
        // before it, so it is not a word in its own right and takes no part in the class sequence.
        let table = transitionTable
        let classIDs = edges.map { table?.classIDs(for: $0) }
        let boundaryIDs = table?.classIDs(for: nil)
        // Cost of edge `next` directly after edge `previous`; nil stands for the start or end of text.
        func transitionCost(_ previous: Int?, _ next: Int?) -> Int {
            guard let table, let boundaryIDs else { return 0 }
            if let previous, edges[previous].isAbsorbedBoundCharacter { return 0 }
            if let next, edges[next].isAbsorbedBoundCharacter { return 0 }
            let from = previous.flatMap { classIDs[$0] } ?? boundaryIDs
            let to = next.flatMap { classIDs[$0] } ?? boundaryIDs
            return table.cost(from: from, to: to)
        }

        var bestScore: [Int: Int] = [:]
        var back: [Int: Int?] = [:]

        for i in sortedIndices {
            let edge = edges[i]
            let nodeCost = SegmenterScoring.edgeCost(edge)

            if edge.start == text.startIndex {
                let startCost = nodeCost + transitionCost(nil, i)
                bestScore[i] = startCost
                back[i] = nil
                edges[i].viterbiScore = startCost
                edges[i].viterbiPrevStart = startOffsets[i]
                continue
            }

            var bestT: Int?
            var bestPrev: Int?

            for prev in edgesByEnd[edge.start] ?? [] {
                guard let prevScore = bestScore[prev] else { continue }
                let t = transitionCost(prev, i)
                if shouldLogPOSTransitions && t != 0 {
                    AppLog.debug(.segmentation, "POS transition \(edges[prev].surface) → \(edge.surface) \(t)")
                }
                let score = prevScore + nodeCost + t
                if bestT == nil || score < bestT! { bestT = score; bestPrev = prev }
            }

            if let resolved = bestT {
                bestScore[i] = resolved
                back[i] = bestPrev
                edges[i].viterbiScore = resolved
                edges[i].viterbiPrevStart = bestPrev.map { startOffsets[$0] }
            }
        }

        // A path's total includes the transition from its last word into the end of text.
        let terminals = edges.indices.filter { edges[$0].end == text.endIndex && bestScore[$0] != nil }
        let terminalScore: (Int) -> Int = { index in
            (bestScore[index] ?? Int.max / 2) + transitionCost(index, nil)
        }
        guard let best = terminals.min(by: { terminalScore($0) < terminalScore($1) }) else {
            return (edges: edges, path: [])
        }

        var pathIndices: [Int] = []
        var cur: Int? = best
        while let idx = cur { pathIndices.append(idx); cur = back[idx] ?? nil }
        let path = pathIndices.reversed().map { edges[$0] }
        return (edges: edges, path: path)
    }

}
