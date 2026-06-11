import Foundation

// Builds segmentation lattice edges by querying dictionary prefix matches at each text position.
nonisolated final class Segmenter: TextSegmenting, @unchecked Sendable {

    private let trie: DictionaryTrie
    private let deinflector: Deinflector?
    private let config: SegmenterConfig
    private let scoring: SegmenterScoring
    // Per-entry POS bitfields loaded from the dictionary; empty when built without metadata.
    private let partOfSpeechByEntryID: [Int: UInt64]
    // Surface → unified frequency score (~0–7 Zipf-equivalent; higher = more common), derived from
    // jpdb_rank (and wordfreq Zipf when present). Two consumers:
    //   • edgeCost — the core statistical node cost of the global path (rare words cost more).
    //   • preferredLemmaScore — frequency tiebreak between equally-script-matched lemma candidates.
    // Empty when the segmenter is built without the surface-reading map (e.g., test fixtures); in
    // that case the scoring falls back to the script-only tiebreakers and a zero frequency term.
    private let frequencyScoreBySurface: [String: Double]
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
        frequencyScoreBySurface: [String: Double] = [:]
    ) {
        self.trie = trie
        self.deinflector = deinflector
        self.partOfSpeechByEntryID = partOfSpeechByEntryID
        self.config = config
        self.scoring = scoring
        self.frequencyScoreBySurface = frequencyScoreBySurface
    }

    // Generates all dictionary-backed lattice edges for every start position in the input text.
    func buildLattice(for text: String) -> [LatticeEdge] {
        var edges: [LatticeEdge] = []

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

                // Hard rejection: a single morpheme never spans a hiragana↔katakana boundary. Once
                // the scan has consumed both scripts, this surface (and every longer one from this
                // start) is spurious, so stop extending. Without this, the kana-normalizing
                // deinflector resolves cross-boundary spans to real words (ビロード+の→「ドの」→どの,
                // ケンカ+もした→「カもした」→醸す) and the frequency-blind cost model selects them.
                if ScriptClassifier.mixesHiraganaAndKatakana(surface) { break }

                let lemmas = resolvedTrieLemmas(for: surface)

                if lemmas.isEmpty == false {
                    // Bound single-kana morphemes (た、ら、etc.) are excluded; only standalone-valid kana pass.
                    if surface.count == 1, ScriptClassifier.isPureKana(surface), !config.standaloneKana.contains(surface) {
                        continue
                    }
                    // Populate POS + dict flag so Viterbi's transitionCost has data to work with.
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
                    edge.isDictionaryMatch = true
                    // Best (highest) frequency score across the surface and its resolved lemmas.
                    // Conjugated surfaces (流されて) carry no direct score, so the lemma (流される)
                    // supplies it. Feeds the statistical term in SegmenterScoring.edgeCost.
                    var freqScore = frequencyScoreBySurface[surface] ?? 0
                    for lemma in lemmas {
                        if let lemmaScore = frequencyScoreBySurface[lemma], lemmaScore > freqScore {
                            freqScore = lemmaScore
                        }
                    }
                    edge.frequencyScore = freqScore
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
                let fallbackRange = unknownFallbackRange(in: text, startingAt: index)
                edges.append(
                    LatticeEdge(
                        start: fallbackRange.lowerBound,
                        end: fallbackRange.upperBound,
                        surface: String(text[fallbackRange])
                    )
                )
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

        print("=== LATTICE (\(edges.count) edges) ===")
        for startOffset in byStart.keys.sorted() {
            print("\(startOffset):")
            for edge in byStart[startOffset]!.sorted(by: { $0.surface < $1.surface }) {
                let endOffset = text.distance(from: text.startIndex, to: edge.end)
                let lemmas = resolvedTrieLemmas(for: edge.surface).sorted()
                if lemmas.isEmpty {
                    print("  [\(startOffset),\(endOffset)) \(escapedForDebug(edge.surface))")
                } else {
                    for lemma in lemmas {
                        let summary = debugResolutionSummary(for: edge.surface, lemma: lemma)
                        print("  [\(startOffset),\(endOffset)) \(escapedForDebug(edge.surface)) → \(escapedForDebug(lemma)) [\(summary)]")
                    }
                }
            }
        }
        print("================")
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
    // Path selection is local longest-match ("greedy") by default; when the strategy is
    // SegmenterSettings.usesGlobalLongestMatch, the same lattice is re-scored via the Viterbi DP
    // (POS bigram + node costs) and the minimum-cost path is returned instead. The global branch
    // is opt-in so changing the strategy in Settings instantly reverts to the long-shipped local
    // behavior — no rebuild needed.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge]) {
        let latticeEdges = buildLattice(for: text)

        if SegmenterSettings.usesGlobalLongestMatch {
            let (annotatedEdges, path) = viterbiSelect(from: latticeEdges, in: text)
            // If Viterbi fails to terminate (no path reaches text.endIndex), fall through to greedy
            // so we never return a partial / empty segmentation. This keeps the flag safe to flip.
            if !path.isEmpty {
                return (latticeEdges: annotatedEdges, selectedEdges: path)
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
                    let afterSmallTsu = text.index(after: nextPos)
                    let hasCandidateAfter = edgesByStart[nextPos]?.contains { e in
                        e.end > nextPos && e.end <= afterSmallTsu
                    } == false
                    // If there are multi-char candidates starting at っ (e.g. った, って) it's fine.
                    let hasMultiCharCandidate = edgesByStart[nextPos]?.contains { e in
                        text.distance(from: e.start, to: e.end) > 1
                    } ?? false
                    return hasMultiCharCandidate || !hasCandidateAfter
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

        return (latticeEdges: latticeEdges, selectedEdges: selectedEdges)
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

        if lhsDerivedLemma.count != rhsDerivedLemma.count {
            return lhsDerivedLemma.count < rhsDerivedLemma.count
        }

        return lhsDerivedLemma > rhsDerivedLemma
    }

    // Determines how far an unknown segment should extend by grouping contiguous same-script runs.
    private func unknownFallbackRange(in text: String, startingAt index: String.Index) -> Range<String.Index> {
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

            // Stop before standalone particles so they get their own edge rather than being absorbed
            // into an unknown run (e.g. だ must not consume ね when ね is a standalone particle).
            if config.standaloneKana.contains(String(character)) { break }

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

    // Checks whether a surface string exists directly in the dictionary trie without deinflection.
    func containsSurface(_ surface: String) -> Bool {
        matchedTrieLemmas(for: surface).isEmpty == false
    }

    // Checks whether a surface resolves through the same trie plus deinflection path used by segmentation.
    func resolvesSurface(_ surface: String) -> Bool {
        resolvedTrieLemmas(for: surface).isEmpty == false
    }

    // Picks the highest-priority resolved lemma for a surface, preferring script-preserving kanji matches.
    func preferredLemma(for surface: String) -> String? {
        lemmaCandidates(for: surface).first
    }

    // Returns the trie-backed lemma candidates for `surface`, sorted
    // best-first by `preferredLemmaScore` with the same length / lexicographic
    // tiebreakers `preferredLemma` used to fold into a single answer. The
    // picker presents these to the user in this order, with the auto-picked
    // candidate appearing first.
    //
    // POS gating: when `surface` differs from the candidate (i.e. the
    // deinflector applied a transition), the candidate must have at least
    // one dictionary entry whose POS bits indicate a verb or adjective —
    // only those parts of speech actually conjugate. Without this filter
    // the deinflector mechanically yields any 2-char noun ending in -う/-つ/-る
    // for the past-tense なった (なつ, なう, etc.), polluting the picker
    // with semantically impossible candidates. When `surface == candidate`
    // the gate is skipped — the user typed the dictionary form directly,
    // so all POS classes are legitimate.
    func lemmaCandidates(for surface: String) -> [String] {
        let lemmas = resolvedTrieLemmas(for: surface)
        guard lemmas.isEmpty == false else { return [] }

        let conjugating = lemmas.filter { lemma in
            if lemma == surface { return true }
            guard let meta = trie.hitMeta(for: lemma) else { return false }
            return meta.entryIDs.contains { entryID in
                let bits = partOfSpeechByEntryID[entryID] ?? 0
                return PartOfSpeech.isVerb(bits) || PartOfSpeech.isAdjective(bits)
            }
        }
        // Fall back to the unfiltered set when the filter eliminates
        // everything — POS data might be sparse for some entries, and an
        // imperfect candidate list is more useful than an empty one.
        let pool = conjugating.isEmpty ? lemmas : conjugating

        return pool.sorted { lhs, rhs in
            let lhsScore = preferredLemmaScore(for: lhs, sourceSurface: surface)
            let rhsScore = preferredLemmaScore(for: rhs, sourceSurface: surface)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs < rhs
        }
    }

    // Resolves all trie-backed lemmas reachable from a surface, including alternate candidates from the deinflector
    // and iteration mark expansion (々, ゝ, ヽ).
    private func resolvedTrieLemmas(for surface: String) -> Set<String> {
        var lemmas = matchedTrieLemmas(for: surface)
        let hasExactSurfaceMatch = trie.contains(surface)

        // Expand iteration marks (e.g. 人々→人人) so reduplicated forms resolve through the trie.
        let expandedCandidates = ScriptClassifier.iterationExpandedCandidates(for: surface)
        for expanded in expandedCandidates where expanded != surface {
            lemmas.formUnion(matchedTrieLemmas(for: expanded))
        }

        if let deinflector {
            let candidates = deinflector.generateCandidates(for: surface)
            for candidate in candidates {
                if hasExactSurfaceMatch, candidate != surface, deinflector.isNormalizedKanaCandidate(candidate, for: surface) {
                    continue
                }
                lemmas.formUnion(matchedTrieLemmas(for: candidate))
            }

            // Second deinflection pass for derivational bases. A lexicalized れる/られる form
            // (生まれる, 流される) is a complete dictionary verb, so the first pass halts there and
            // never reaches its base (生む, 流す). But jpdb attaches frequency to the base, and the
            // base is a legitimate alternate lemma the user may want to see — so re-deinflect each
            // first-pass れる-form once more and add any trie-backed base as an ADDITIONAL candidate.
            // preferredLemmaScore still ranks the surface-closest lexicalized form first, so this
            // only widens the candidate set (feeding the frequency term + the lemma picker); it does
            // not change the chosen primary lemma. Gated on the れる suffix to keep it cheap and
            // scoped to the passive/spontaneous/potential class where the base carries the frequency.
            let firstPassLemmas = lemmas
            for lemma in firstPassLemmas where lemma != surface && lemma.hasSuffix("れる") {
                for base in deinflector.generateCandidates(for: lemma) where base != lemma {
                    lemmas.formUnion(matchedTrieLemmas(for: base))
                }
            }
        }

        return lemmas
    }

    // Builds a debug summary showing how the current resolver pipeline admits one emitted lemma for a surface.
    func debugResolutionSummary(for surface: String, lemma: String) -> String {
        let (exactLemmas, alternateResolutions) = debugResolutionSources(for: surface)
        let matchingAlternateCandidates = alternateResolutions
            .filter { resolution in
                resolution.lemmas.contains(lemma)
            }
            .map { resolution in
                resolution.candidate
            }
            .sorted()

        var parts = [
            "exact_hits: \(exactLemmas.count)",
            "alternate_hits: \(alternateResolutions.count)"
        ]

        if exactLemmas.contains(lemma) {
            parts.append("exact_match")
        }

        if matchingAlternateCandidates.isEmpty == false {
            parts.append("via: \(matchingAlternateCandidates.joined(separator: ", "))")
        }

        if let deinflector, lemma != surface {
            let transitions = deinflector.bestTransitions(for: surface, targetLemma: lemma) ?? []
            if transitions.isEmpty == false {
                let transStr = transitions.map { "\($0.kanaIn)→\($0.kanaOut)" }.joined(separator: ", ")
                parts.append("path: \(transStr)")
            }
        }

        return parts.joined(separator: "; ")
    }

    // Enumerates exact and alternate candidate resolutions using the same admission rules as lattice generation.
    private func debugResolutionSources(for surface: String) -> (exactLemmas: Set<String>, alternateResolutions: [(candidate: String, lemmas: Set<String>)]) {
        let exactLemmas = matchedTrieLemmas(for: surface)
        let hasExactSurfaceMatch = trie.contains(surface)
        var alternateResolutions: [(candidate: String, lemmas: Set<String>)] = []

        if let deinflector {
            let candidates = deinflector.generateCandidates(for: surface).sorted()
            for candidate in candidates {
                if candidate == surface {
                    continue
                }

                if hasExactSurfaceMatch,
                   deinflector.isNormalizedKanaCandidate(candidate, for: surface) {
                    continue
                }

                let lemmas = matchedTrieLemmas(for: candidate)
                if lemmas.isEmpty == false {
                    alternateResolutions.append((candidate: candidate, lemmas: lemmas))
                }
            }
        }

        return (exactLemmas, alternateResolutions)
    }

    // Resolves direct trie-backed membership lemmas for a surface without alternate-surface recovery.
    private func matchedTrieLemmas(for surface: String) -> Set<String> {
        var lemmas: Set<String> = []

        if trie.contains(surface) {
            lemmas.insert(surface)
        }

        return lemmas
    }

    // Scores competing lemmas so furigana and segmentation can favor script-preserving dictionary forms.
    //
    // Frequency term (`wordfreqZipfByLemma`) breaks ties between candidates
    // that the script-based rules above can't distinguish. The classic case
    // is the past-tense collision なった ⇒ {なう, なる}: both are pure-kana
    // lemmas of the same length, so without a frequency signal the prior
    // Unicode-codepoint tiebreaker arbitrarily picked the rarer なう. Zipf
    // is roughly 1 (very rare) to 7 (extremely common); scaling by 5 puts
    // a Zipf-6 word ~30 points ahead of a Zipf-0 word, enough to dominate
    // the existing ±40-point script signals when they're tied.
    private func preferredLemmaScore(for lemma: String, sourceSurface: String) -> Int {
        var score = 0

        if lemma == sourceSurface {
            score += LemmaScoring.surfaceEqualityBonus
        }

        if ScriptClassifier.containsKanji(sourceSurface) {
            if ScriptClassifier.containsKanji(lemma) {
                score += LemmaScoring.kanjiPreservedBonus
            } else if ScriptClassifier.isPureKana(lemma) {
                score += LemmaScoring.kanjiToKanaPenalty
            }
        }

        if ScriptClassifier.isPureKana(sourceSurface) && ScriptClassifier.isPureKana(lemma) {
            score += LemmaScoring.pureKanaBonus
        }

        // Prefer lemmas whose leading chars match the surface — the closer the
        // lemma's stem is to the surface, the more directly the deinflection
        // chain reached it. Disambiguates modern vs classical verbs that share
        // the same inflected form (e.g. 忘れる shares 「忘れ」 with 忘れない,
        // 忘る only 「忘」). 5 points per char yields ~10-point separation per
        // mora — enough to break ties without overpowering wordfreq or the
        // surface-equality bonus.
        let commonPrefixCount = lemma.commonPrefix(with: sourceSurface).count
        score += commonPrefixCount * LemmaScoring.prefixMatchPerChar

        if let freqScore = frequencyScoreBySurface[lemma], freqScore > 0 {
            score += Int(freqScore * LemmaScoring.frequencyMultiplier)
        }

        return score
    }

    // Tunable weights for preferredLemmaScore. Grouped (like SegmenterScoring's transition
    // costs) so the empirical calibration lives in one place instead of as bare literals
    // scattered through the scoring body. Magnitudes are interdependent — see the
    // preferredLemmaScore doc comment for why ±40 script signals must outweigh frequency.
    private enum LemmaScoring {
        static let surfaceEqualityBonus = 100   // lemma identical to the surface form
        static let kanjiPreservedBonus = 40     // kanji surface → kanji lemma (script preserved)
        static let kanjiToKanaPenalty = -20     // kanji surface → kana-only lemma (script lost)
        static let pureKanaBonus = 10           // both surface and lemma are pure kana
        static let prefixMatchPerChar = 5       // per shared leading character
        static let frequencyMultiplier = 5.0    // scales the wordfreq Zipf signal into points
    }

    // Prints greedy longest-match segments line-by-line for segmenter debugging.
    func debugPrintSegments(for text: String) {
        let segments = longestMatchSegments(for: text)

        for segment in segments {
            print(String(text[segment]))
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

    // Selects the minimum-cost lattice path using Viterbi DP with POS transition costs.
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

        var bestScore: [Int: Int] = [:]
        var back: [Int: Int?] = [:]

        for i in sortedIndices {
            let edge = edges[i]
            let nodeCost = SegmenterScoring.edgeCost(edge)

            if edge.start == text.startIndex {
                bestScore[i] = nodeCost
                back[i] = nil
                edges[i].viterbiScore = nodeCost
                edges[i].viterbiPrevStart = startOffsets[i]
                continue
            }

            var bestT: Int?
            var bestPrev: Int?

            for prev in edgesByEnd[edge.start] ?? [] {
                guard let prevScore = bestScore[prev] else { continue }
                let t = SegmenterScoring.transitionCost(prev: edges[prev], next: edge)
                if shouldLogPOSTransitions && t != 0 {
                    print("POS transition \(edges[prev].surface) → \(edge.surface) \(t)")
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

        let terminals = edges.indices.filter { edges[$0].end == text.endIndex && bestScore[$0] != nil }
        guard let best = terminals.min(by: { (bestScore[$0] ?? Int.max) < (bestScore[$1] ?? Int.max) }) else {
            return (edges: edges, path: [])
        }

        var pathIndices: [Int] = []
        var cur: Int? = best
        while let idx = cur { pathIndices.append(idx); cur = back[idx] ?? nil }
        let path = pathIndices.reversed().map { edges[$0] }
        return (edges: edges, path: path)
    }

}
