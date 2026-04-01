import Foundation

// Explicit dictionary search mode used by the Words tab search UI.
enum DictionarySearchMode: String, CaseIterable, Identifiable {
    case japanese
    case english

    var id: String { rawValue }

    // Short segmented-control label used in the Words search chrome.
    var title: String {
        switch self {
        case .japanese:
            return "JP"
        case .english:
            return "EN"
        }
    }
}
