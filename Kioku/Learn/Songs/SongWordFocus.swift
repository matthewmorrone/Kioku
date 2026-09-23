import Foundation

// The word listen-along is on right now: set when a word's surface (sung snippet or reading)
// plays, kept through its definition and closing reading, and cleared when the script moves to
// a line, gist or pattern row. Shown in the Breakdown's mini player, and what tapping it scrolls
// back to.
nonisolated struct SongWordFocus: Equatable {
    let lineIndex: Int
    let surface: String
}
