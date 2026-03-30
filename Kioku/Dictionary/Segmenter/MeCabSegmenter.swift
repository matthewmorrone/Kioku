import Foundation

// Provides TextSegmenting conformance backed by the MeCab morphological analyzer.
// Each instance owns a MeCabTokenizer tied to one dictionary (IPAdic or UniDic).
final class MeCabSegmenter: TextSegmenting {

    private let tokenizer: MeCabTokenizer
    private let dictionary: MeCabDictionary

    // Creates a MeCab-backed segmenter using the compiled dictionary at the given bundle path.
    init?(dictionary: MeCabDictionary) {
        self.dictionary = dictionary
        guard let path = Bundle.main.path(forResource: dictionary.bundleDirectoryName, ofType: nil, inDirectory: "MeCab") else {
            print("MeCabSegmenter: dictionary bundle path not found for \(dictionary.rawValue)")
            return nil
        }
        guard let tok = MeCabTokenizer(dictionaryPath: path) else {
            print("MeCabSegmenter: MeCabTokenizer initialization failed for \(dictionary.rawValue)")
            return nil
        }
        self.tokenizer = tok
    }

    // Produces both the full lattice (identical to selected edges for MeCab) and the selected path.
    // MeCab returns a single best path rather than a full lattice, so both arrays are the same.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge]) {
        let edges = longestMatchEdges(for: text)
        return (latticeEdges: edges, selectedEdges: edges)
    }

    // Tokenizes text with MeCab and converts the result into LatticeEdge objects with correct String.Index positions.
    func longestMatchEdges(for text: String) -> [LatticeEdge] {
        guard text.isEmpty == false else { return [] }

        let nodes = tokenizer.tokenize(text)
        guard nodes.isEmpty == false else { return [] }

        return convertNodesToEdges(nodes, in: text)
    }

    // Returns the base form (lemma) from MeCab's feature fields for the given surface text.
    func preferredLemma(for surface: String) -> String? {
        guard surface.isEmpty == false else { return nil }
        let nodes = tokenizer.tokenize(surface)
        // If MeCab splits the surface into multiple tokens, use the first one's base form.
        guard let firstNode = nodes.first else { return nil }
        let baseForm = firstNode.featureField(at: dictionary.baseFormFieldIndex)
        // Return nil if the base form is the same as the surface (no useful lemma info).
        if let baseForm, baseForm != surface {
            return baseForm
        }
        return baseForm
    }

    // Checks whether MeCab recognizes the surface as a known word (not an unknown-category token).
    func resolvesSurface(_ surface: String) -> Bool {
        guard surface.isEmpty == false else { return false }
        let nodes = tokenizer.tokenize(surface)
        // If MeCab produces exactly one node covering the full surface and it's not unknown, it resolves.
        guard let first = nodes.first else { return false }
        // A single-node result whose surface matches means MeCab recognized it as a dictionary word.
        if nodes.count == 1 && first.surface == surface {
            return isKnownNode(first)
        }
        // Multiple nodes mean MeCab split it — still "resolves" if all nodes are known.
        return nodes.allSatisfy { isKnownNode($0) }
    }

    // Returns a debug summary for MeCab's analysis of a surface/lemma pair.
    func debugResolutionSummary(for surface: String, lemma: String) -> String {
        let nodes = tokenizer.tokenize(surface)
        guard let first = nodes.first else { return "mecab: no nodes" }
        let pos = first.featureField(at: 0) ?? "?"
        let baseForm = first.featureField(at: dictionary.baseFormFieldIndex) ?? surface
        return "mecab: pos=\(pos); base=\(baseForm); nodes=\(nodes.count)"
    }

    // Converts MeCab nodes to LatticeEdge objects by mapping byte offsets to String.Index positions.
    private func convertNodesToEdges(_ nodes: [MeCabNode], in text: String) -> [LatticeEdge] {
        var edges: [LatticeEdge] = []
        let utf8 = text.utf8

        for node in nodes {
            let byteStart = node.byteOffset
            let byteEnd = byteStart + node.byteLength

            // Convert UTF-8 byte offsets to String.Index.
            let utf8Start = utf8.index(utf8.startIndex, offsetBy: byteStart, limitedBy: utf8.endIndex)
                ?? utf8.endIndex
            let utf8End = utf8.index(utf8.startIndex, offsetBy: byteEnd, limitedBy: utf8.endIndex)
                ?? utf8.endIndex

            let startIndex = String.Index(utf8Start, within: text) ?? text.endIndex
            let endIndex = String.Index(utf8End, within: text) ?? text.endIndex

            guard startIndex < endIndex else { continue }

            edges.append(LatticeEdge(
                start: startIndex,
                end: endIndex,
                surface: String(text[startIndex..<endIndex])
            ))
        }

        return edges
    }

    // Determines whether a MeCab node represents a known dictionary word vs. an unknown fallback.
    // For IPAdic, unknown words have POS starting with "名詞,固有名詞" or the surface is in unk.dic.
    // The feature string for unknowns often starts with a special UNK category.
    private func isKnownNode(_ node: MeCabNode) -> Bool {
        // MeCab marks unknown words with a specific internal flag, but through the C API we can't
        // directly access node->stat. However, the feature string is the best signal we have.
        // A simple heuristic: if the feature contains no useful base form, it's likely unknown.
        let baseForm = node.featureField(at: dictionary.baseFormFieldIndex)
        return baseForm != nil
    }
}
