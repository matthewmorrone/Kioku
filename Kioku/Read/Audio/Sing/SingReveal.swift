import Foundation

// Whether Sing mode hides the words it listens for while you sing: shown as usual, each hidden
// until it's graded, or all hidden until you stop.
enum SingReveal: String, CaseIterable {
    case show
    case asGraded
    case atEnd

    static let storageKey = "kioku.sing.reveal"

    // The name shown in the options sheet.
    var label: String {
        switch self {
        case .show: return "Show lyrics"
        case .asGraded: return "Reveal as graded"
        case .atEnd: return "Reveal at end"
        }
    }
}
