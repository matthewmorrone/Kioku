import Foundation

// Which of the two phone views a cast lyric video draws.
enum TVCastMode: String, CaseIterable {
    case words
    case lyrics
}

// Everything the lyric video is drawn from: the song's audio, its words in song order with their
// meanings, and the display choices (furigana, meanings) in force when it was made. `cacheKey`
// changes whenever any of that does, so a stale video is never reused.
struct LyricVideoInput {
    let noteID: UUID?
    let audioURL: URL
    let durationMs: Int
    let words: [WordFocusWord]
    let glosses: [Int: String]
    let showsFurigana: Bool
    let showsMeanings: Bool
    let cacheKey: String
}
