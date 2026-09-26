import SwiftUI

// Renders the Settings theme chooser: one swatch card per built-in theme, side by side. Each
// card paints the theme's own background with a sample of its text colors (the two segment
// colors on its surface) over an accent rule, then a row of dots for the selection and Saved /
// Learned / Not Learned highlight colors. The selected card gets an accent border; the theme's
// name sits under each card.
struct ThemeSwatchPicker: View {
    @Binding var themeIDRaw: String

    var body: some View {
        let activeID = ThemeID(rawValue: themeIDRaw) ?? .system
        HStack(spacing: 12) {
            ForEach(ThemeID.allCases) { id in
                swatch(for: id, isSelected: id == activeID)
                    .onTapGesture {
                        themeIDRaw = id.rawValue
                        Theme.setActive(id)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(id.displayName)
                    .accessibilityAddTraits(id == activeID ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    // One theme's card plus its name — the unit the HStack repeats.
    private func swatch(for id: ThemeID, isSelected: Bool) -> some View {
        let palette = ThemePalette.palette(for: id)
        return VStack(spacing: 6) {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text("文").foregroundStyle(hexColor(palette.defaultTokenColorAHex))
                    Text("字").foregroundStyle(hexColor(palette.defaultTokenColorBHex))
                }
                .font(.system(size: 22, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(palette.uiSurface))
                )
                .overlay(alignment: .bottom) {
                    Color(palette.uiAccent).frame(height: 3)
                        .clipShape(Capsule())
                        .padding(.horizontal, 10)
                }
                HStack(spacing: 5) {
                    dot(palette.defaultHighlightHex)
                    dot(palette.defaultSavedHex)
                    dot(palette.defaultSavedLearnedHex)
                    dot(palette.defaultSavedNotLearnedHex)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(palette.uiBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accent : Color.secondary.opacity(0.3),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            Text(id.displayName)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // One small highlight-color dot.
    private func dot(_ hex: String) -> some View {
        Circle()
            .fill(hexColor(hex))
            .frame(width: 10, height: 10)
    }

    // Palette hexes are compile-time constants, so a parse failure is a typo; show it as gray
    // rather than crash.
    private func hexColor(_ hex: String) -> Color {
        Color(UIColor(hexString: hex) ?? .gray)
    }
}
