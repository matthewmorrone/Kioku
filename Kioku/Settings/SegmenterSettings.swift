import Foundation

// Centralizes UserDefaults keys and defaults for the segmentation backend configuration.
nonisolated enum SegmenterSettings {
    static let backendKey = "kioku.segmenter.backend"
    static let mecabDictionaryKey = "kioku.segmenter.mecabDictionary"
    static let viterbiEnabledKey = "kioku.segmenter.viterbiEnabled"
    static let defaultBackend = SegmenterBackend.trie.rawValue
    static let defaultMeCabDictionary = MeCabDictionary.ipadic.rawValue
    static let defaultViterbiEnabled = false

    // Runtime probe for the trie segmenter's selection strategy.
    // Read on the Segmenter's worker thread, so this must stay a cheap
    // UserDefaults lookup rather than an actor-isolated property.
    static var isViterbiEnabled: Bool {
        UserDefaults.standard.object(forKey: viterbiEnabledKey) as? Bool ?? defaultViterbiEnabled
    }
}
