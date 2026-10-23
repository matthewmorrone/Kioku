import Foundation

// What a breakdown's **Fix:** line corrects (SongBreakdownPrompt rules 12 and 13): a word's reading,
// where the line's words break, or a typo in the text itself.
nonisolated enum SongLineFixKind: String, Codable, Sendable {
    case reading
    case split
    case typo
}
