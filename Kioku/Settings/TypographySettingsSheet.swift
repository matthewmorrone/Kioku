import SwiftUI

// Renders the typography editor sheet opened from the Settings preview: the live preview pinned
// at the top, then one slider per typography value (text size, furigana size, line spacing,
// furigana spacing, kerning).
struct TypographySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(TypographySettings.customFuriganaSizeEnabledKey) private var customFuriganaSizeEnabled = false
    @AppStorage(TypographySettings.furiganaSizeKey) private var furiganaSize = TypographySettings.defaultFuriganaSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TypographyPreview()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Form {
                    sliderRow("Text Size", value: $textSize, range: TypographySettings.textSizeRange, step: 1, format: "%.0f")
                    sliderRow("Furigana Size", value: furiganaSizeBinding, range: TypographySettings.furiganaSizeRange, step: 1, format: "%.0f")
                    sliderRow("Line Spacing", value: $lineSpacing, range: TypographySettings.lineSpacingRange, step: 1, format: "%.0f")
                    sliderRow("Furigana Spacing", value: $furiganaGap, range: TypographySettings.furiganaGapRange, step: 0.5, format: "%.1f")
                    sliderRow("Kerning", value: $kerning, range: TypographySettings.kerningRange, step: 1, format: "%.1f")
                }
                .scrollContentBackground(.hidden)
            }
            .washiBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .themedTint()
        .presentationDetents([.medium, .large])
    }

    // One labelled slider with its current value on the right — the shape every row here shares.
    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // Furigana follows half the text size (and so tracks pinch-zoom in the Read tab) until this
    // slider is first moved; from then on it's the size the user picked.
    private var furiganaSizeBinding: Binding<Double> {
        Binding(
            get: {
                customFuriganaSizeEnabled
                    ? furiganaSize
                    : (textSize * Double(TypographySettings.furiganaSizeFactor)).rounded()
            },
            set: {
                furiganaSize = $0
                customFuriganaSizeEnabled = true
            }
        )
    }
}
