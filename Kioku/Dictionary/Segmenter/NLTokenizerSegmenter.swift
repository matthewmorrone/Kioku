import Foundation
import NaturalLanguage

// Provides TextSegmenting conformance backed by Apple's NLTokenizer for Japanese word segmentation.
// Uses the built-in ICU tokenizer with zero external dependencies.
nonisolated final class NLTokenizerSegmenter: TextSegmenting {

    // Tokenizes text using NLTokenizer at the word level with Japanese locale.
    // Returns identical lattice and selected edges since NLTokenizer produces a single segmentation.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge]) {
        let edges = longestMatchEdges(for: text)
        return (latticeEdges: edges, selectedEdges: edges)
    }

    // Segments text into word-level tokens using Apple's Natural Language framework.
    func longestMatchEdges(for text: String) -> [LatticeEdge] {
        guard text.isEmpty == false else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.japanese)
        tokenizer.string = text

        var edges: [LatticeEdge] = []
        // Enumerate all word tokens in the text and convert each range to a LatticeEdge.
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let surface = String(text[range])
            edges.append(LatticeEdge(start: range.lowerBound, end: range.upperBound, surface: surface))
            return true
        }

        return edges
    }

    // NLTokenizer does not provide lemma information, so returns nil.
    func preferredLemma(for surface: String) -> String? {
        nil
    }

    // Checks whether NLTokenizer recognizes the surface as a single token rather than splitting it.
    func resolvesSurface(_ surface: String) -> Bool {
        guard surface.isEmpty == false else { return false }
        let edges = longestMatchEdges(for: surface)
        return edges.count == 1 && edges.first?.surface == surface
    }

    // Returns a debug summary for NLTokenizer's analysis of a surface.
    func debugResolutionSummary(for surface: String, lemma: String) -> String {
        let edges = longestMatchEdges(for: surface)
        return "nltokenizer: tokens=\(edges.count)"
    }
}
