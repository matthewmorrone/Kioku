import SwiftUI

// Renders a single cell in the kana chart, showing the current representation.
// Major sections: text content, empty-cell placeholder.
struct KanaCellView: View {
    let entry: KanaEntry?
    let representation: KanaRepresentation
    // Cell height is derived from available screen space so the whole chart fits without scrolling.
    var height: CGFloat = 36

    // Selects the string to display for the current representation.
    private func text(for entry: KanaEntry) -> String {
        switch representation {
            case .hiragana: return entry.hiragana
            case .katakana: return entry.katakana
            case .romaji:   return entry.romaji
            case .ipa:      return entry.ipa
        }
    }

    // Determines whether the text should use a larger kana font or smaller latin font.
    private var isLatin: Bool {
        representation == .romaji || representation == .ipa
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.secondarySystemBackground))

            if let entry {
                Text(text(for: entry))
                    // Font scales with the cell so glyphs stay proportional at any derived height.
                    .font(.system(size: height * (isLatin ? 0.32 : 0.55), weight: .regular))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    // Crossfade the glyph when the representation changes via swipe.
                    .contentTransition(.opacity)
            }
        }
        .frame(height: height)
    }
}
