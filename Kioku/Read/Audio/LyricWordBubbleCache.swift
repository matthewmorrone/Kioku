import Foundation

// Reference-type memo for the lyrics card's word bubbles (LyricsView+WordBubbles): the bubbles of
// the last cue asked for and the signature of the inputs they were built from. Held by @State and
// mutated in place, so building them during `body` doesn't write SwiftUI state, and the dictionary
// lookups behind them run once per line rather than once per playback frame.
final class LyricWordBubbleCache {
    var signature: Int?
    var bubbles: [LyricWordBubble] = []
}
