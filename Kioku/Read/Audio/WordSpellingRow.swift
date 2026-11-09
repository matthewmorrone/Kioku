import SwiftUI

// One word's spelling in a single line at one size: furigana over each kanji run, plain text
// between. Shared by the word-by-word view and the TV lyrics view so both draw ruby the same way.
struct WordSpellingRow: View {
    let word: WordFocusWord
    let size: CGFloat
    let showsFurigana: Bool

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(Array(word.pieces.enumerated()), id: \.offset) { _, piece in
                VStack(spacing: 2) {
                    Text(piece.ruby ?? " ")
                        .font(Font(ReadingFont.body(size: size * 0.45)))
                        .opacity(piece.ruby == nil || showsFurigana == false ? 0 : 1)
                    Text(piece.base)
                        .font(Font(ReadingFont.body(size: size)))
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
