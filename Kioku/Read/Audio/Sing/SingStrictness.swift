import Foundation
import LyricAlignment

// How much of a word Sing mode must hear before it counts as sung: the share of the word's
// vowels and, separately, of its consonants that the model has to pick up.
nonisolated enum SingStrictness: String, CaseIterable, Codable {
    case lenient
    case normal
    case strict

    static let storageKey = "kioku.sing.strictness"

    // The share of vowels and of consonants that must be heard.
    var passFraction: Double {
        switch self {
        case .lenient: return 1.0 / 3.0
        case .normal: return SingPhonemeScorer.passFraction
        case .strict: return 0.75
        }
    }

    // The name shown in the options sheet and the session history.
    var label: String {
        switch self {
        case .lenient: return "Lenient"
        case .normal: return "Normal"
        case .strict: return "Strict"
        }
    }
}
