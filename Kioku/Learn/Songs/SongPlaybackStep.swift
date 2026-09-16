import Foundation

// Where the breakdown's floating mini player is parked: before the first line (the song's
// instrumental/vocal intro), on a specific line, or after the last line (the outro). Backs the
// mini player's next/previous navigation and the current-position label in SongStepperView+
// MiniPlayer, and is persisted (see SongListenStore) so reopening a note's breakdown — even
// after an app relaunch — remembers where playback left off.
enum SongPlaybackStep: Equatable {
    case intro
    case line(Int)
    case outro

    // Plain-string encoding for UserDefaults — simpler than Codable ceremony for one small enum.
    var persistedValue: String {
        switch self {
        case .intro: return "intro"
        case .line(let index): return "line:\(index)"
        case .outro: return "outro"
        }
    }

    // Inverse of persistedValue, for restoring from UserDefaults. Nil for anything unrecognized
    // (e.g. a key that predates this type) rather than defaulting silently to a guess.
    static func from(persistedValue raw: String) -> SongPlaybackStep? {
        if raw == "intro" { return .intro }
        if raw == "outro" { return .outro }
        let linePrefix = "line:"
        if raw.hasPrefix(linePrefix), let index = Int(raw.dropFirst(linePrefix.count)) {
            return .line(index)
        }
        return nil
    }
}
