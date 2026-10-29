import Foundation

// Whether Listen-along iterates through a line's split view — the word-by-word steps (snippet,
// reading, definition) after the line and its gist. Chosen in the Breakdown options menu and
// stored raw in UserDefaults (BreakdownListenSettings.wordWalkKey).
nonisolated enum BreakdownWordWalk: String, CaseIterable, Sendable {
    // Walk every line's words, expanding its card as the reading reaches them.
    case yes
    // Read only the line and its gist; never step through the words.
    case no
    // Walk the words only of lines whose card the user already has expanded.
    case ifExpanded

    // The options menu's label for this choice.
    var title: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .ifExpanded: return "If Expanded"
        }
    }

    // Whether a line's words are walked, given whether its card is expanded. One rule shared by the
    // script builder so the menu choice can't drift from what is spoken.
    func walksWords(lineIsExpanded: Bool) -> Bool {
        switch self {
        case .yes: return true
        case .no: return false
        case .ifExpanded: return lineIsExpanded
        }
    }
}
