import SwiftUI

// One lyric line's English translation as the lyrics card shows it: italic light text on a dark
// plate, so it reads over the white tails of the word bubbles. Used by the card (under the line)
// and by the bubble overlay (which redraws it in front of the tails), so both look the same and
// the hand-over between them is invisible. A plain content view with no layout of its own.
struct LyricTranslationText: View {
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(size: 12)
            .foregroundStyle(Color.white.opacity(0.7))
            .italic()
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
    }
}
