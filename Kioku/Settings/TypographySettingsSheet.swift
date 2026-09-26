import SwiftUI

// Renders the full-height typography editor sheet opened from the Settings preview: the live
// preview at the top, then one slider per typography value (text size, furigana size, line
// spacing, furigana spacing, kerning) plus the furigana auto-size toggle.
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
            Form {
                // The preview sits in the form as its own card row, so it shares the slider
                // section's side margins.
                Section {
                    TypographyPreview()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    sliderRow("Text Size", value: $textSize, range: TypographySettings.textSizeRange, step: 1, format: "%.0f")
                    Toggle("Auto Furigana Size", isOn: autoFuriganaSizeBinding)
                    if customFuriganaSizeEnabled {
                        sliderRow("Furigana Size", value: $furiganaSize, range: TypographySettings.furiganaSizeRange, step: 1, format: "%.0f")
                    }
                    sliderRow("Line Spacing", value: $lineSpacing, range: TypographySettings.lineSpacingRange, step: 1, format: "%.0f")
                    sliderRow("Furigana Spacing", value: $furiganaGap, range: TypographySettings.furiganaGapRange, step: 0.5, format: "%.1f")
                    sliderRow("Kerning", value: $kerning, range: TypographySettings.kerningRange, step: 1, format: "%.1f")
                }
            }
            .scrollContentBackground(.hidden)
            .washiBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .themedTint()
        .presentationDetents([.large])
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

    // On = furigana tracks half the text size and the Furigana Size slider is hidden; off = the
    // slider appears and furigana keeps the size set on it.
    private var autoFuriganaSizeBinding: Binding<Bool> {
        Binding(
            get: { !customFuriganaSizeEnabled },
            set: { isAuto in
                // Turning auto off starts the slider at the size furigana was just tracking, so
                // nothing jumps.
                if !isAuto {
                    furiganaSize = (textSize * Double(TypographySettings.furiganaSizeFactor)).rounded()
                }
                customFuriganaSizeEnabled = !isAuto
            }
        )
    }
}
