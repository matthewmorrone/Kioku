import Foundation

// One run of a word's spelling for the word-focus view: `base` is the text drawn large, `ruby` the
// reading drawn above it (nil for kana and anything else that needs none).
struct WordFocusPiece: Equatable {
    let base: String
    let ruby: String?
}

// One word of the song for the word-focus view, in song order: where the note puts it, the pieces of
// its spelling with their furigana, and when it starts being sung (ms).
struct WordFocusWord: Equatable, Identifiable {
    let id: Int
    let surface: String
    let pieces: [WordFocusPiece]
    let startMs: Int
}

// What the word list was built from; a change to any part rebuilds it (a shuffle swaps the song under the open view).
struct WordListKey: Hashable {
    let noteID: UUID?
    let textLength: Int
    let cueCount: Int
}
