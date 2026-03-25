import Foundation

// Builds segmentation lattice edges by querying dictionary prefix matches at each text position.
final class Segmenter {

    private let trie: DictionaryTrie
    private let deinflector: Deinflector?
    private let config: SegmenterConfig
    private let scoring: SegmenterScoring
    private let boundaryCharacters: Set<Character> = [
        " ", "\t", "\n", "\r", "　",
        ".", ",", "!", "?", ";", ":",
        "。", "、", "！", "？", "・",
        "「", "」", "『", "』",
        "(", ")", "（", "）",
        "[", "]", "{", "}",
        "-", "—", "…", "，", "．"
    ]

    // Stores trie dependency used for prefix lookup when constructing lattices.
    init(
        trie: DictionaryTrie,
        deinflector: Deinflector? = nil,
        config: SegmenterConfig = SegmenterConfig(),
        scoring: SegmenterScoring = .default
    ) {
        self.trie = trie
        self.deinflector = deinflector
        self.config = config
        self.scoring = scoring
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
                let lemmas = resolvedTrieLemmas(for: surface)

                if lemmas.isEmpty == false {
                    // Bound single-kana morphemes (た、ら、etc.) are excluded; only standalone-valid kana pass.
                    if surface.count == 1, ScriptClassifier.isPureKana(surface), !config.standaloneKana.contains(surface) {
                        continue
                    }
                    edges.append(
                        LatticeEdge(
                            start: surfaceRange.lowerBound,
                            end: surfaceRange.upperBound,
                            surface: surface
                        )
                    )
                    keptMatches += 1
                }
            }

            // Ensures every character position has at least one outgoing edge.
            // Single-character fallback so the greedy walk lands on every position,
            // allowing dictionary words that start mid-unknown-run to be reached.
            if keptMatches == 0 {
                let nextIndex = text.index(after: index)
                edges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: String(text[index..<nextIndex])
                    )
                )
            }

            index = text.index(after: index)
        }

        return edges
    }

    // Prints lattice edges with integer offsets and matched text for segmenter debugging.
    func debugPrintLattice(for text: String) {
        var index = text.startIndex

        while index < text.endIndex {
            if boundaryCharacters.contains(text[index]) {
                let nextIndex = text.index(after: index)
                let boundarySurface = String(text[index..<nextIndex])
                let startOffset = text.distance(from: text.startIndex, to: index)
                let endOffset = text.distance(from: text.startIndex, to: nextIndex)
                print("\(startOffset)→\(endOffset) \(boundarySurface) [lemma: \(boundarySurface)]")
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
                let surface = String(text[surfaceRange])
                let characterLength = text.distance(from: surfaceRange.lowerBound, to: surfaceRange.upperBound)
                if characterLength > config.maxMatchLength {
                    break
                }

                let startOffset = text.distance(from: text.startIndex, to: surfaceRange.lowerBound)
                let endOffset = text.distance(from: text.startIndex, to: surfaceRange.upperBound)

                let matchedLemmas = resolvedTrieLemmas(for: surface).sorted()
                if matchedLemmas.isEmpty == false {
                    for lemma in matchedLemmas {
                        let resolutionSummary = debugResolutionSummary(for: surface, lemma: lemma)
                        print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [lemma: \(escapedForDebug(lemma))] [\(resolutionSummary)]")
                        keptMatches += 1

                        if keptMatches >= config.maxMatchesPerPosition {
                            break
                        }
                    }
                } else {
                    // print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [no-match]")
                }

                if keptMatches >= config.maxMatchesPerPosition {
                    break
                }
            }

            if keptMatches == 0 {
                let nextIndex = text.index(after: index)
                let fallbackSurface = String(text[index..<nextIndex])
                let startOffset = text.distance(from: text.startIndex, to: index)
                let endOffset = text.distance(from: text.startIndex, to: nextIndex)
                print("\(startOffset)→\(endOffset) \(escapedForDebug(fallbackSurface)) [lemma: \(escapedForDebug(fallbackSurface))] [fallback]")
            }

            index = text.index(after: index)
        }
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
            if index == text.endIndex {
                return [[]]
            }
            if let cached = memo[index] {
                return cached
            }
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

    // Produces both the full candidate lattice and the currently selected greedy path for one text snapshot.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge]) {
        let latticeEdges = buildLattice(for: text)
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
        let lhsLength = text.distance(from: lhs.start, to: lhs.end)
        let rhsLength = text.distance(from: rhs.start, to: rhs.end)

        // Give single-char pure-kana particles a small bonus so single-char deinflection-only kana
        // edges (e.g. もき → もく) can't beat them, while still allowing genuinely longer deinflected
        // forms (e.g. つないだ→つなぐ over つな, かなえて→かなえる over かなえ) to win on raw length.
        // The bonus is intentionally restricted to single-char kana: applying it to multi-char stems
        // like かなえ causes them to tie with — and then beat — longer deinflected forms like かなえて.
        let kanaExactBonus = 1
        let lhsAdjustedLength = lhsLength + (lhs.surface.count == 1 && ScriptClassifier.isPureKana(lhs.surface) && trie.contains(lhs.surface) ? kanaExactBonus : 0)
        let rhsAdjustedLength = rhsLength + (rhs.surface.count == 1 && ScriptClassifier.isPureKana(rhs.surface) && trie.contains(rhs.surface) ? kanaExactBonus : 0)
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
            if boundaryCharacters.contains(character) || isLineBreakCharacter(character) {
                break
            }

            if ScriptClassifier.unknownGrouping(for: character) != group {
                break
            }

            currentIndex = text.index(after: currentIndex)
            groupedLength += 1
        }

        return index..<currentIndex
    }
    // Applies unknown penalty to non-dictionary non-boundary edges so punctuation separators are not over-penalized.
    private func shouldApplyUnknownSegmentPenalty(_ edge: LatticeEdge) -> Bool {
        if isDictionaryEdge(edge) {
            return false
        }

        for character in edge.surface {
            if !boundaryCharacters.contains(character) {
                return true
            }
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
        let lemmas = resolvedTrieLemmas(for: surface)
        guard lemmas.isEmpty == false else {
            return nil
        }

        return lemmas.max { lhs, rhs in
            let lhsScore = preferredLemmaScore(for: lhs, sourceSurface: surface)
            let rhsScore = preferredLemmaScore(for: rhs, sourceSurface: surface)

            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }

            return lhs > rhs
        }
    }

    // Resolves all trie-backed lemmas reachable from a surface, including alternate candidates from the deinflector.
    private func resolvedTrieLemmas(for surface: String) -> Set<String> {
        var lemmas = matchedTrieLemmas(for: surface)
        let hasExactSurfaceMatch = trie.contains(surface)

        if let deinflector {
            let candidates = deinflector.generateCandidates(for: surface)
            for candidate in candidates {
                if hasExactSurfaceMatch,
                   candidate != surface,
                   deinflector.isNormalizedKanaCandidate(candidate, for: surface) {
                    continue
                }
                lemmas.formUnion(matchedTrieLemmas(for: candidate))
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
    private func preferredLemmaScore(for lemma: String, sourceSurface: String) -> Int {
        var score = 0

        if lemma == sourceSurface {
            score += 100
        }

        if ScriptClassifier.containsKanji(sourceSurface) {
            if ScriptClassifier.containsKanji(lemma) {
                score += 40
            } else if ScriptClassifier.isPureKana(lemma) {
                score -= 20
            }
        }

        if ScriptClassifier.isPureKana(sourceSurface) && ScriptClassifier.isPureKana(lemma) {
            score += 10
        }

        return score
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

    // Escapes control line-break characters for stable single-line debug output.
    private func escapedForDebug(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

}
