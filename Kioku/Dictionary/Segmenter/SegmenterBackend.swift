import Foundation

// Enumerates the available text segmentation engines so Settings can present a backend picker.
enum SegmenterBackend: String, CaseIterable {
    case trie
    case mecab

    // Returns a human-readable label for display in the settings picker.
    var displayName: String {
        switch self {
        case .trie: return "Dictionary (Trie)"
        case .mecab: return "MeCab"
        }
    }
}
