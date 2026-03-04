import Foundation

// Builds segmentation lattice edges by querying dictionary prefix matches at each text position.
final class Segmenter {

    private let trie: DictionaryTrie
    private let config: SegmenterConfig
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
    init(trie: DictionaryTrie, config: SegmenterConfig = SegmenterConfig()) {
        self.trie = trie
        self.config = config
    }

    // Generates all dictionary-backed lattice edges for every start position in the input text.
    func buildLattice(for text: String) -> [LatticeEdge] {
        var edges: [LatticeEdge] = []

        var index = text.startIndex

        while index < text.endIndex {
            if boundaryCharacters.contains(text[index]) {
                let nextIndex = text.index(after: index)
                edges.append(LatticeEdge(start: index, end: nextIndex))
                index = nextIndex
                continue
            }

            let matches = trie.prefixMatches(in: text, startingAt: index)
            var keptMatches = 0

            for match in matches {
                let matchLength = text.distance(from: match.lowerBound, to: match.upperBound)
                guard matchLength <= config.maxMatchLength else {
                    continue
                }

                guard keptMatches < config.maxMatchesPerPosition else {
                    break
                }

                edges.append(
                    LatticeEdge(
                        start: match.lowerBound,
                        end: match.upperBound
                    )
                )
                keptMatches += 1
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
            print("\(startOffset)→\(endOffset) \(matchedText)")
        }
    }
}
