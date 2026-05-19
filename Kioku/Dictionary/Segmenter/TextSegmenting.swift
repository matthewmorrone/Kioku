import Foundation

// Defines the shared interface for text segmentation backends so the app can swap implementations.
nonisolated protocol TextSegmenting: Sendable {
    // Produces both the full candidate lattice and the currently selected greedy path for one text snapshot.
    func longestMatchResult(for text: String) -> (latticeEdges: [LatticeEdge], selectedEdges: [LatticeEdge])

    // Builds a greedy segmentation edge list so downstream features can use chosen surface/lemma references.
    func longestMatchEdges(for text: String) -> [LatticeEdge]

    // Picks the highest-priority resolved lemma for a surface.
    func preferredLemma(for surface: String) -> String?

    // Returns all dictionary-backed lemma candidates for a surface, ordered
    // best-first by the same scoring used to pick `preferredLemma`. Powers
    // the "Choose lemma…" picker that lets the user override the segmenter's
    // automatic pick when the surface is ambiguous (e.g. なった ⇒ なる or なう).
    // Returns an empty array when no lemmas resolve through the pipeline.
    func lemmaCandidates(for surface: String) -> [String]

    // Checks whether a surface resolves through the segmenter's resolution pipeline.
    func resolvesSurface(_ surface: String) -> Bool

    // Builds a debug summary showing how the resolver pipeline admits one emitted lemma for a surface.
    func debugResolutionSummary(for surface: String, lemma: String) -> String
}
