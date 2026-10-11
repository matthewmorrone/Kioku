import Foundation

// Folding a loaded dictionary into the launch-time placeholder Segmenter, in place. Split out of
// Segmenter.swift to keep that file under the line-count guardrail.
extension Segmenter {
    // Swaps in fully-loaded dictionary data while preserving this instance's identity — see the
    // property-group comment above for why identity stability matters more than a fresh init here.
    func reconfigure(
        trie: DictionaryTrie,
        deinflector: Deinflector?,
        partOfSpeechByEntryID: [Int: UInt64],
        frequencyScoreBySurface: [String: Double],
        commonKanaSurfaces: Set<String>,
        transitionTable: SegmenterTransitionTable?,
        nameSurfaces: Set<String>,
        nameReadingLookup: (@Sendable (String) -> String?)?,
        bestWordRankByKana: [String: Int]
    ) {
        self.bestWordRankByKana = bestWordRankByKana
        useNameSurfaces(nameSurfaces)
        self.nameReadingLookup = nameReadingLookup
        self.transitionTable = transitionTable
        self.commonKanaSurfaces = commonKanaSurfaces
        self.trie = trie
        self.deinflector = deinflector
        self.partOfSpeechByEntryID = partOfSpeechByEntryID
        self.frequencyScoreBySurface = frequencyScoreBySurface
        if trie.surfaceCount > 0 {
            loadGate.markLoaded()
        }
    }

    // Convenience for ContentView's startup sequence, which builds a brand-new Segmenter on a
    // background thread and needs to fold its data into the already-published placeholder
    // instance rather than replacing it — see the property-group comment above.
    func reconfigure(from other: Segmenter) {
        // Before the main reconfigure, which opens the load gate: nothing released by it may
        // segment without the boundary model.
        boundaryModel = other.boundaryModel
        reconfigure(
            trie: other.trie,
            deinflector: other.deinflector,
            partOfSpeechByEntryID: other.partOfSpeechByEntryID,
            frequencyScoreBySurface: other.frequencyScoreBySurface,
            commonKanaSurfaces: other.commonKanaSurfaces,
            transitionTable: other.transitionTable,
            nameSurfaces: other.nameSurfaces,
            nameReadingLookup: other.nameReadingLookup,
            bestWordRankByKana: other.bestWordRankByKana
        )
    }
}
