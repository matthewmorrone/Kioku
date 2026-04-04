import Foundation

// Controls the visual layout of inactive cue rows in the lyrics popup.
// The active cue row appearance is the same across all styles.
enum LyricsDisplayStyle: String, CaseIterable {
    case appleMusic
    case accentBar
    case focusCard

    // Display name shown in Settings.
    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .accentBar: return "Accent Bar"
        case .focusCard: return "Focus Card"
        }
    }

    static let storageKey = "kioku.settings.lyricsDisplayStyle"
    static let defaultValue = LyricsDisplayStyle.appleMusic
}
