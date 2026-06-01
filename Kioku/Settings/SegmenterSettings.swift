import Foundation

// The trie segmenter's path-selection strategy. Both strategies walk the *same* lattice from
// Segmenter.buildLattice; they differ only in the scope of each boundary decision.
//   • localLongestMatch  — a.k.a. "greedy": take the longest edge at each position and commit,
//     with no lookahead. Fast, but can strand un-parseable fragments downstream.
//   • globalLongestMatch — minimize total path cost across the whole line, computed by the
//     Viterbi DP. Sees the entire line before deciding, so it won't paint itself into a corner.
nonisolated enum SegmentationStrategy: String {
    case localLongestMatch
    case globalLongestMatch
}

// Centralizes UserDefaults keys and defaults for the segmentation backend configuration.
nonisolated enum SegmenterSettings {
    static let backendKey = "kioku.segmenter.backend"
    static let mecabDictionaryKey = "kioku.segmenter.mecabDictionary"
    static let strategyKey = "kioku.segmenter.strategy"
    static let defaultBackend = SegmenterBackend.trie.rawValue
    static let defaultMeCabDictionary = MeCabDictionary.ipadic.rawValue
    static let defaultStrategy = SegmentationStrategy.localLongestMatch

    // Runtime probe for the trie segmenter's selection strategy.
    // Read on the Segmenter's worker thread, so this must stay a cheap
    // UserDefaults lookup rather than an actor-isolated property.
    static var strategy: SegmentationStrategy {
        UserDefaults.standard.string(forKey: strategyKey)
            .flatMap(SegmentationStrategy.init(rawValue:)) ?? defaultStrategy
    }

    // Convenience for the one call site that only needs to know whether to run the global
    // (Viterbi) path instead of the local greedy walk.
    static var usesGlobalLongestMatch: Bool {
        strategy == .globalLongestMatch
    }
}
