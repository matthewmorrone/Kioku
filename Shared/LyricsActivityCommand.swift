import Foundation

// A transport button pressed on the lyrics Live Activity. Carried from the button's App Intent to
// the app's players by LyricsActivityCommandRelay.
nonisolated enum LyricsActivityCommand: Sendable {
    case togglePlayback
    case previousLine
    case nextLine
}
