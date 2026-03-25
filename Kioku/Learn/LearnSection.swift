import Foundation

// The top-level sections available in the Learn tab.
enum LearnSection: String, CaseIterable {
    case kana
    case cards

    // Label shown in the segmented picker.
    var displayName: String {
        switch self {
        case .kana: return "Kana"
        case .cards: return "Study"
        }
    }
}
