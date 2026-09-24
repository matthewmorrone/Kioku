import SwiftUI

// One tappable tile on the Matching board (either column). Renders the text on a rounded card
// whose fill and outline reflect the tile's state: neutral, selected (accent outline), wrong (red
// flash), or matched (faded, no longer tappable). Fixed height so the two columns' rows line up.
struct MatchingTile: View {
    let text: String
    // English glosses run long and read fine smaller; Japanese script gets the larger face.
    let isMeaning: Bool
    let state: MatchingTileState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(isMeaning ? .body.weight(.medium) : .title3.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                .background(background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(state == .selected ? Color.accentColor : .clear, lineWidth: 2)
                )
                .foregroundStyle(state == .wrong ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .opacity(state == .matched ? 0.25 : 1)
        .allowsHitTesting(state != .matched)
        .animation(.easeOut(duration: 0.15), value: state)
    }

    // Card fill for the current state.
    private var background: Color {
        switch state {
        case .idle, .matched: return Color(.secondarySystemBackground)
        case .selected: return Color.accentColor.opacity(0.18)
        case .wrong: return .red
        }
    }
}
