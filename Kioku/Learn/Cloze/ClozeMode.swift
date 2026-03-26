import Foundation

// Controls whether cloze sentences are presented in note order or shuffled randomly.
enum ClozeMode: String, CaseIterable, Identifiable {
    case sequential
    case random

    var id: String { rawValue }

    // Human-readable label used in the mode picker.
    var displayName: String {
        switch self {
        case .sequential: return "In order"
        case .random: return "Random"
        }
    }
}
