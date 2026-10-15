import Foundation

// One word of a lyric line with what its bubbles on the lyrics card say: `gloss` in a speech
// bubble above it (its meaning — the song breakdown's, else the dictionary's), `comment` in a
// thought bubble below (the breakdown's note on it). Either may be nil; a word with neither gets
// no bubble. `noteRange` is in the note's UTF-16 coordinates.
struct LyricWordBubble: Equatable {
    let noteRange: NSRange
    let gloss: String?
    let comment: String?
}

// One bubble placed for drawing: its word's rect on the card and the bubble's text, keyed by the
// word's note location.
struct PlacedLyricWordBubble: Equatable {
    let id: Int
    let anchor: CGRect
    let gloss: String?
    let comment: String?
}
