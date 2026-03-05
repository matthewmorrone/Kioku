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
                        lemma: boundarySurface
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
                var lemmas: Set<String> = []

                if trie.contains(surface) {
                    lemmas.insert(surface)
                }

                if let deinflector {
                    let candidates = deinflector.generateCandidates(for: surface)
                    for candidate in candidates where trie.contains(candidate) {
                        lemmas.insert(candidate)
                    }
                }

                for lemma in lemmas {
                    edges.append(
                        LatticeEdge(
                            start: surfaceRange.lowerBound,
                            end: surfaceRange.upperBound,
                            surface: surface,
                            lemma: lemma
                        )
                    )
                    keptMatches += 1
                }
            }

            // Ensures every character position has at least one outgoing edge.
            if keptMatches == 0 {
                let fallbackRange = unknownFallbackRange(in: text, startingAt: index)
                let fallbackSurface = String(text[fallbackRange])
                edges.append(
                    LatticeEdge(
                        start: fallbackRange.lowerBound,
                        end: fallbackRange.upperBound,
                        surface: fallbackSurface,
                        lemma: fallbackSurface
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
                        // print("\(startOffset)→\(endOffset) \(escapedForDebug(surface)) [no-match]")
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

    // Determines how far an unknown token should extend by grouping contiguous same-script runs.
    private func unknownFallbackRange(in text: String, startingAt index: String.Index) -> Range<String.Index> {
        let firstCharacter = text[index]
        guard let group = unknownGrouping(for: firstCharacter) else {
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

            if unknownGrouping(for: character) != group {
                break
            }

            currentIndex = text.index(after: currentIndex)
            groupedLength += 1
        }

        return index..<currentIndex
    }

    // Classifies unknown-token script groups used for simple fallback token coalescing.
    private func unknownGrouping(for character: Character) -> String? {
        guard let scalar = character.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value
        if (0x3040...0x309F).contains(value) {
            return "hiragana"
        }

        if (0x30A0...0x30FF).contains(value) {
            return "katakana"
        }

        if (0x0030...0x0039).contains(value) || (0xFF10...0xFF19).contains(value) {
            return "number"
        }

        if (0x0041...0x005A).contains(value) ||
           (0x0061...0x007A).contains(value) ||
           (0xFF21...0xFF3A).contains(value) ||
           (0xFF41...0xFF5A).contains(value) {
            return "latin"
        }

        return nil
    }

    // Applies unknown penalty to non-dictionary non-boundary edges so punctuation separators are not over-penalized.
    private func shouldApplyUnknownTokenPenalty(_ edge: LatticeEdge) -> Bool {
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
        trie.contains(edge.surface) || trie.contains(edge.lemma)
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
        text.replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

}
