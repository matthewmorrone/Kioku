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

// Centralizes the UserDefaults key and default for the segmenter's path-selection strategy.
nonisolated enum SegmenterSettings {
    static let strategyKey = "kioku.segmenter.strategy"
    static let defaultStrategy = SegmentationStrategy.globalLongestMatch

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
