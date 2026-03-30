import Foundation

// Centralizes UserDefaults keys and defaults for the segmentation backend configuration.
enum SegmenterSettings {
    static let backendKey = "kioku.segmenter.backend"
    static let mecabDictionaryKey = "kioku.segmenter.mecabDictionary"
    static let defaultBackend = SegmenterBackend.trie.rawValue
    static let defaultMeCabDictionary = MeCabDictionary.ipadic.rawValue
}
