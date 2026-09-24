import Foundation

// What an imported audio file mostly is, per AudioContentClassifier: spoken, sung (or music), or
// too ambiguous to call.
enum AudioContentKind: Equatable {
    case speech
    case singing
    case unclear
}
