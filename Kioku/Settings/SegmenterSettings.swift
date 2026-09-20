import Foundation

// The trie segmenter's path-selection strategy. Both strategies walk the *same* lattice from
// Segmenter.buildLattice; they differ in how a path through it is chosen.
//   • localLongestMatch  — a.k.a. "greedy": take the longest edge at each position and commit,
//     with no lookahead, consulting the SegmentationDemotions list. Can strand fragments downstream.
//   • globalLongestMatch — minimize total path cost across the whole line with the Viterbi DP,
//     where each word costs −ln P of its surface as written (SegmenterScoring.edgeCost). Sees the
//     entire line before deciding, and does not consult the demotion list.
// Raw values are persisted in UserDefaults, so they stay fixed even though the display names differ.
nonisolated enum SegmentationStrategy: String, CaseIterable {
    case localLongestMatch
    case globalLongestMatch

    // Returns a human-readable label for display in the settings picker.
    var displayName: String {
        switch self {
        case .localLongestMatch: return "Longest Match (Greedy)"
        case .globalLongestMatch: return "Word Frequency (Viterbi)"
        }
    }
}

// Centralizes UserDefaults keys and defaults for the segmentation backend configuration.
nonisolated enum SegmenterSettings {
    static let backendKey = "kioku.segmenter.backend"
    static let mecabDictionaryKey = "kioku.segmenter.mecabDictionary"
    static let strategyKey = "kioku.segmenter.strategy"
    static let splitsParticleClustersKey = "kioku.segmenter.splitsParticleClusters"
    static let defaultBackend = SegmenterBackend.trie.rawValue
    static let defaultMeCabDictionary = MeCabDictionary.ipadic.rawValue
    static let defaultStrategy = SegmentationStrategy.globalLongestMatch
    static let defaultSplitsParticleClusters = true

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

    // Whether a chosen particle-cluster entry (には, ですか — see ParticleClusters) is shown as its
    // parts. Read on the Segmenter's worker thread, like `strategy`.
    static var splitsParticleClusters: Bool {
        UserDefaults.standard.object(forKey: splitsParticleClustersKey) as? Bool ?? defaultSplitsParticleClusters
    }
}
