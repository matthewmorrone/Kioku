import Foundation

// Builds segmentation lattice edges by querying dictionary prefix matches at each text position.
final class Segmenter {

    private let trie: DictionaryTrie
    private let deinflector: Deinflector?
    private let config: SegmenterConfig
    private let maxTokenLength = 20
    private let boundaryCharacters: Set<Character> = [
        " ", "\t", "\n", "\r", "　",
        ".", ",", "!", "?", ";", ":",
        "。", "、", "！", "？", "・",
        "「", "」", "『", "』",
        "(", ")", "（", "）",
        "[", "]", "{", "}",
        "-", "—", "…", "，", "．"
    ]
    private let particleSurfaces: Set<String> = [
        "に", "を", "が", "は", 
        "で", "と", "へ", "も", 
        "や", "の", "か", "ね", 
        "よ", "な", "ぞ", "さ", 
        "わ"
    ]

    // Stores trie dependency used for prefix lookup when constructing lattices.
    init(trie: DictionaryTrie, deinflector: Deinflector? = nil, config: SegmenterConfig = SegmenterConfig()) {
        self.trie = trie
        self.deinflector = deinflector
        self.config = config
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
                        pos: "boundary",
                        cost: nodeCost(isDictionaryWord: true, length: 1)
                    )
                )
                index = nextIndex
                continue
            }

            // Walks only dictionary-valid prefixes from this position via trie traversal.
            let effectiveMaxTokenLength = min(maxTokenLength, config.maxMatchLength)
            let scanResult = trie.prefixScan(in: text, startingAt: index, maxLength: effectiveMaxTokenLength)
            let prefixRanges = scanResult.matches
            var keptMatches = 0
            var seenEdgeKeys = Set<String>()
            var hasDictionaryMatch = false

            for surfaceRange in prefixRanges {
                let characterLength = text.distance(from: surfaceRange.lowerBound, to: surfaceRange.upperBound)
                guard characterLength <= effectiveMaxTokenLength else {
                    continue
                }

                let surface = String(text[surfaceRange])
                let startOffset = text.distance(from: text.startIndex, to: surfaceRange.lowerBound)
                let endOffset = text.distance(from: text.startIndex, to: surfaceRange.upperBound)
                let edgeKey = "\(startOffset):\(endOffset):\(surface)"
                guard seenEdgeKeys.insert(edgeKey).inserted else {
                    continue
                }

                edges.append(
                    LatticeEdge(
                        start: surfaceRange.lowerBound,
                        end: surfaceRange.upperBound,
                        surface: surface,
                        lemma: surface,
                        pos: inferredPartOfSpeech(surface: surface, lemma: surface),
                        cost: nodeCost(isDictionaryWord: true, length: characterLength)
                    )
                )
                hasDictionaryMatch = true
                keptMatches += 1

                if keptMatches >= config.maxMatchesPerPosition {
                    break
                }
            }

            // Runs deinflection only as fallback when no dictionary match exists at this position.
            if !hasDictionaryMatch, let deinflector, scanResult.scannedEnd > index, keptMatches < config.maxMatchesPerPosition {
                // Uses exactly one full span from the current position to the farthest trie-scanned index.
                // Do not deinflect partial substrings generated during scanning.
                let fullScannedRange = index..<scanResult.scannedEnd
                let fullSurface = String(text[fullScannedRange])
                let endsInHiragana = fullSurface.last?.unicodeScalars.allSatisfy { scalar in
                    (0x3040...0x309F).contains(scalar.value)
                } ?? false
                guard endsInHiragana else {
                    index = text.index(after: index)
                    continue
                }
                let candidates = deinflector.deinflect(fullSurface).sorted()

                for candidate in candidates {
                    guard trie.contains(candidate) else {
                        continue
                    }

                    let startOffset = text.distance(from: text.startIndex, to: fullScannedRange.lowerBound)
                    let endOffset = text.distance(from: text.startIndex, to: fullScannedRange.upperBound)
                    let edgeKey = "\(startOffset):\(endOffset):\(candidate)"
                    guard seenEdgeKeys.insert(edgeKey).inserted else {
                        continue
                    }

                    edges.append(
                        LatticeEdge(
                            start: fullScannedRange.lowerBound,
                            end: fullScannedRange.upperBound,
                            surface: fullSurface,
                            lemma: candidate,
                            pos: inferredPartOfSpeech(surface: fullSurface, lemma: candidate),
                            cost: nodeCost(
                                isDictionaryWord: true,
                                length: text.distance(from: fullScannedRange.lowerBound, to: fullScannedRange.upperBound)
                            )
                        )
                    )
                    keptMatches += 1

                    if keptMatches >= config.maxMatchesPerPosition {
                        break
                    }
                }
            }

            if !hasDictionaryMatch && keptMatches == 0 {
                let nextIndex = text.index(after: index)
                let unknownSurface = String(text[index..<nextIndex])
                edges.append(
                    LatticeEdge(
                        start: index,
                        end: nextIndex,
                        surface: unknownSurface,
                        lemma: unknownSurface,
                        pos: inferredPartOfSpeech(surface: unknownSurface, lemma: unknownSurface),
                        cost: nodeCost(isDictionaryWord: false, length: 1)
                    )
                )
            }

            index = text.index(after: index)
        }

        return edges
    }

    // Prints lattice edges with integer offsets and matched text for tokenizer debugging.
    func debugPrintLattice(for text: String) {
        let edges = buildLattice(for: text)

        for edge in edges {
            let startOffset = text.distance(from: text.startIndex, to: edge.start)
            let endOffset = text.distance(from: text.startIndex, to: edge.end)
            let matchedText = String(text[edge.start..<edge.end])
            print("\(startOffset)→\(endOffset) \(matchedText) [lemma: \(edge.lemma)]")
        }
    }

    // Builds a greedy segmentation by selecting the farthest-reaching edge at each text index.
    func longestMatchSegments(for text: String) -> [Range<String.Index>] {
        let bestPath = viterbiBestPath(for: text)
        if !bestPath.isEmpty {
            return bestPath.map { edge in
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

    // Selects the minimum-cost segmentation path using dynamic programming with backpointers.
    func viterbiBestPath(for text: String) -> [LatticeEdge] {
        let edges = buildLattice(for: text)
        guard !edges.isEmpty else {
            return []
        }

        var edgeIndicesByEnd: [String.Index: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            edgeIndicesByEnd[edge.end, default: []].append(index)
        }

        let sortedEdgeIndices = edges.indices.sorted { lhs, rhs in
            let leftEnd = edges[lhs].end
            let rightEnd = edges[rhs].end
            if leftEnd == rightEnd {
                let leftStart = edges[lhs].start
                let rightStart = edges[rhs].start
                return text.distance(from: text.startIndex, to: leftStart) < text.distance(from: text.startIndex, to: rightStart)
            }

            return text.distance(from: text.startIndex, to: leftEnd) < text.distance(from: text.startIndex, to: rightEnd)
        }

        var bestCostByEdgeIndex: [Int: Int] = [:]
        var backpointerByEdgeIndex: [Int: Int?] = [:]

        for edgeIndex in sortedEdgeIndices {
            let edge = edges[edgeIndex]
            let previousEdgeIndices = edgeIndicesByEnd[edge.start] ?? []

            if edge.start == text.startIndex {
                bestCostByEdgeIndex[edgeIndex] = edge.cost
                backpointerByEdgeIndex[edgeIndex] = nil
                continue
            }

            var bestCandidateCost: Int?
            var bestPreviousEdgeIndex: Int?

            for previousEdgeIndex in previousEdgeIndices {
                guard let previousCost = bestCostByEdgeIndex[previousEdgeIndex] else {
                    continue
                }

                let transition = transitionCost(from: edges[previousEdgeIndex], to: edge)
                let candidateCost = previousCost + transition + edge.cost

                if let currentBestCost = bestCandidateCost {
                    if candidateCost < currentBestCost {
                        bestCandidateCost = candidateCost
                        bestPreviousEdgeIndex = previousEdgeIndex
                    }
                } else {
                    bestCandidateCost = candidateCost
                    bestPreviousEdgeIndex = previousEdgeIndex
                }
            }

            if let bestCandidateCost {
                bestCostByEdgeIndex[edgeIndex] = bestCandidateCost
                backpointerByEdgeIndex[edgeIndex] = bestPreviousEdgeIndex
            }
        }

        let terminalEdges = edges.indices.filter { edgeIndex in
            edges[edgeIndex].end == text.endIndex && bestCostByEdgeIndex[edgeIndex] != nil
        }
        guard let bestTerminalEdgeIndex = terminalEdges.min(by: { lhs, rhs in
            (bestCostByEdgeIndex[lhs] ?? Int.max) < (bestCostByEdgeIndex[rhs] ?? Int.max)
        }) else {
            return []
        }

        var pathIndices: [Int] = []
        var currentEdgeIndex: Int? = bestTerminalEdgeIndex
        while let currentIndex = currentEdgeIndex {
            pathIndices.append(currentIndex)
            currentEdgeIndex = backpointerByEdgeIndex[currentIndex] ?? nil
        }

        return pathIndices.reversed().map { edgeIndex in
            edges[edgeIndex]
        }
    }

    // Computes node-level token cost with unknown-word penalty and short-token bias.
    private func nodeCost(isDictionaryWord: Bool, length: Int) -> Int {
        var cost = isDictionaryWord ? 1 : 5
        if length == 1 {
            cost += 10
        } else if length == 2 {
            cost += 3
        }
        cost -= length
        return cost
    }

    // Computes transition penalty between adjacent lattice nodes using coarse POS heuristics.
    private func transitionCost(from previous: LatticeEdge, to next: LatticeEdge) -> Int {
        let previousPOS = previous.pos ?? inferredPartOfSpeech(surface: previous.surface, lemma: previous.lemma)
        let nextPOS = next.pos ?? inferredPartOfSpeech(surface: next.surface, lemma: next.lemma)

        if isEntirelyHiragana(next.surface) && endsWithKanji(previous.surface) {
            return 8
        }

        if previousPOS == "noun" && nextPOS == "particle" {
            return 0
        }

        if previousPOS == "particle" && nextPOS == "verb" {
            return 0
        }

        if previousPOS == "noun" && nextPOS == "noun" {
            return 3
        }

        if previousPOS == "verb" && nextPOS == "verb" {
            return 3
        }

        return 1
    }

    // Determines whether a token consists entirely of hiragana scalars.
    private func isEntirelyHiragana(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }

        for scalar in text.unicodeScalars {
            if !(0x3040...0x309F).contains(scalar.value) {
                return false
            }
        }

        return true
    }

    // Determines whether the last scalar of a token is a kanji code point.
    private func endsWithKanji(_ text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }

        let value = lastScalar.value
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
    }

    // Infers a coarse part of speech from known particles and lemma-ending heuristics.
    private func inferredPartOfSpeech(surface: String, lemma: String) -> String {
        if particleSurfaces.contains(surface) {
            return "particle"
        }

        if lemma == "する" || lemma == "くる" {
            return "verb"
        }

        if let lastCharacter = lemma.last {
            let lastString = String(lastCharacter)
            if ["る", "う", "く", "ぐ", "す", "つ", "ぬ", "ぶ", "む"].contains(lastString) {
                return "verb"
            }

            if lastString == "い" && lemma.count > 1 {
                return "adjective"
            }
        }

        return "noun"
    }

    // Prints greedy longest-match segments line-by-line for tokenizer debugging.
    func debugPrintSegments(for text: String) {
        let bestPath = viterbiBestPath(for: text)

        if !bestPath.isEmpty {
            for node in bestPath {
                print(node.surface)
            }
            return
        }

        let segments = longestMatchSegments(for: text)
        for segment in segments {
            print(String(text[segment]))
        }
    }
}
