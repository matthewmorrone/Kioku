import Foundation

// Sort options for live dictionary search results in the Words tab.
enum DictionarySearchSortMode: String, CaseIterable, Identifiable {
    case relevance
    case commonFirst
    case alphabetical

    var id: String { rawValue }

    // Human-readable menu label for the Words search controls.
    var title: String {
        switch self {
        case .relevance:
            return "Relevance"
        case .commonFirst:
            return "Common First"
        case .alphabetical:
            return "A-Z"
        }
    }
}
