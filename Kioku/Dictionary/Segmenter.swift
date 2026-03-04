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
                        surface: boundarySurface,
                        lemma: boundarySurface,
                        isDictionaryMatch: false
                    )
                )
                index = nextIndex
                continue
            }

            var keptMatches = 0
            var endIndex = index

            // Scans forward substrings and builds lattice nodes from dictionary or deinflection matches.
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

                if trie.contains(surface) {
                    edges.append(
                        LatticeEdge(
                            start: surfaceRange.lowerBound,
                            end: surfaceRange.upperBound,
                            surface: surface,
                            lemma: surface,
                            isDictionaryMatch: true
                        )
                    )
                    keptMatches += 1
                } else if let deinflector {
                    let candidates = deinflector.generateCandidates(for: surface)
                    let matchedLemmas = candidates
                        .filter { candidate in
                            trie.contains(candidate)
                        }
                        .sorted()

                    for lemma in matchedLemmas {
                        edges.append(
                            LatticeEdge(
                                start: surfaceRange.lowerBound,
                                end: surfaceRange.upperBound,
                                surface: surface,
                                lemma: lemma,
                                isDictionaryMatch: true
                            )
                        )
                        keptMatches += 1

                        if keptMatches >= config.maxMatchesPerPosition {
                            break
                        }
                    }
                }

                if keptMatches >= config.maxMatchesPerPosition {
                    break
                }
            }

            // Ensures every character position has at least one outgoing edge.
            if keptMatches == 0 {
                let nextIndex = text.index(after: index)
                let fallbackSurface = String(text[index..<nextIndex])
                edges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: fallbackSurface,
                        lemma: fallbackSurface,
                        isDictionaryMatch: false
                    )
                )
            }

            index = text.index(after: index)
        }

        return edges
    }

    // Prints lattice edges with integer offsets and matched text for tokenizer debugging.
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

                if trie.contains(surface) {
                    print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [lemma: \(escapedForDebug(surface))]")
                    keptMatches += 1
                } else if let deinflector {
                    let candidates = deinflector.generateCandidates(for: surface)
                    let matchedLemmas = candidates
                        .filter { candidate in
                            trie.contains(candidate)
                        }
                        .sorted()

                    if matchedLemmas.isEmpty {
                        print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [no-match]")
                    } else {
                        for lemma in matchedLemmas {
                            print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [lemma: \(escapedForDebug(lemma))]")
                            keptMatches += 1

                            if keptMatches >= config.maxMatchesPerPosition {
                                break
                            }
                        }
                    }
                } else {
                    print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [no-match]")
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
        let path = viterbiBestPath(for: text)
        if !path.isEmpty {
            return path.map { edge in
                edge.start..<edge.end
            }
        }

        let edges = buildLattice(for: text)
        var edgesByStart: [String.Index: [LatticeEdge]] = [:]

        for edge in edges {
            edgesByStart[edge.start, default: []].append(edge)
        }

        var segments: [Range<String.Index>] = []
        var index = text.startIndex

        while index < text.endIndex {
            if let candidates = edgesByStart[index],
               let longestEdge = candidates.max(by: { lhs, rhs in
                   lhs.end < rhs.end
               }) {
                segments.append(longestEdge.start..<longestEdge.end)
                index = longestEdge.end
            } else {
                let nextIndex = text.index(after: index)
                segments.append(index..<nextIndex)
                index = nextIndex
            }
        }

        return segments
    }

    // Selects the lowest-cost segmentation path from the lattice using a minimal Viterbi pass.
    func viterbiBestPath(for text: String) -> [LatticeEdge] {
        let edges = buildLattice(for: text)
        guard !edges.isEmpty else {
            return []
        }

        var edgesByEnd: [String.Index: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            edgesByEnd[edge.end, default: []].append(index)
        }

        let sortedEdgeIndices = edges.indices.sorted { leftIndex, rightIndex in
            let leftDistance = text.distance(from: text.startIndex, to: edges[leftIndex].end)
            let rightDistance = text.distance(from: text.startIndex, to: edges[rightIndex].end)
            if leftDistance == rightDistance {
                let leftStartDistance = text.distance(from: text.startIndex, to: edges[leftIndex].start)
                let rightStartDistance = text.distance(from: text.startIndex, to: edges[rightIndex].start)
                return leftStartDistance < rightStartDistance
            }

            return leftDistance < rightDistance
        }

        var bestCost: [Int: Int] = [:]
        var backpointer: [Int: Int?] = [:]

        for edgeIndex in sortedEdgeIndices {
            let edge = edges[edgeIndex]
            let length = edge.surface.count
            var nodeCost = scoring.baseCost - (length * scoring.lengthReward)
            if length == 1 {
                nodeCost += scoring.singleCharacterPenalty
            }

            if edge.surface != edge.lemma {
                nodeCost += scoring.deinflectionPenalty
            }

            if edge.isDictionaryMatch {
                nodeCost -= scoring.dictionaryBonus
            }

            if edge.start == text.startIndex {
                bestCost[edgeIndex] = nodeCost
                backpointer[edgeIndex] = nil
                continue
            }

            let previousEdgeIndices = edgesByEnd[edge.start] ?? []
            var bestCandidateCost: Int?
            var bestPreviousIndex: Int?

            for previousEdgeIndex in previousEdgeIndices {
                guard let previousCost = bestCost[previousEdgeIndex] else {
                    continue
                }

                let candidateCost = previousCost + nodeCost
                if let currentBest = bestCandidateCost {
                    if candidateCost < currentBest {
                        bestCandidateCost = candidateCost
                        bestPreviousIndex = previousEdgeIndex
                    }
                } else {
                    bestCandidateCost = candidateCost
                    bestPreviousIndex = previousEdgeIndex
                }
            }

            if let bestCandidateCost {
                bestCost[edgeIndex] = bestCandidateCost
                backpointer[edgeIndex] = bestPreviousIndex
            }
        }

        let terminalEdgeIndices = edges.indices.filter { edgeIndex in
            edges[edgeIndex].end == text.endIndex && bestCost[edgeIndex] != nil
        }

        guard let bestTerminalIndex = terminalEdgeIndices.min(by: { leftIndex, rightIndex in
            (bestCost[leftIndex] ?? Int.max) < (bestCost[rightIndex] ?? Int.max)
        }) else {
            return []
        }

        var pathIndices: [Int] = []
        var currentIndex: Int? = bestTerminalIndex

        while let edgeIndex = currentIndex {
            pathIndices.append(edgeIndex)
            currentIndex = backpointer[edgeIndex] ?? nil
        }

        return pathIndices.reversed().map { edgeIndex in
            edges[edgeIndex]
        }
    }

    // Prints greedy longest-match segments line-by-line for tokenizer debugging.
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
        text
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
