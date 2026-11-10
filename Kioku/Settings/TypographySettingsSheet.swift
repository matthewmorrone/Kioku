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

    // Slider positions while dragging. Writing the stored settings on every tick re-typesets the
    // open note in the Read tab each time, which is what made the sliders sluggish; the drafts
    // move only the preview here, and the stored values are written when the drag ends.
    @State private var draft = TypographyDraft(
        textSize: TypographySettings.defaultTextSize,
        lineSpacing: TypographySettings.defaultLineSpacing,
        kerning: TypographySettings.defaultKerning,
        furiganaGap: TypographySettings.defaultFuriganaGap,
        furiganaSize: TypographySettings.defaultFuriganaSize
    )

    var body: some View {
        NavigationStack {
            Form {
                // The preview sits in the form as its own card row, so it shares the slider
                // section's side margins.
                Section {
                    TypographyPreview(draft: draft)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    sliderRow("Text Size", value: $draft.textSize, commit: { textSize = draft.textSize }, range: TypographySettings.textSizeRange, step: 1, format: "%.0f")
                    Toggle(isOn: autoFuriganaSizeBinding) {
                        Text("Auto Furigana Size")
                            .infoButton("Keep furigana at half the text size. Turn it off to set the size yourself.")
                    }
                    if customFuriganaSizeEnabled {
                        sliderRow("Furigana Size", value: $draft.furiganaSize, commit: { furiganaSize = draft.furiganaSize }, range: TypographySettings.furiganaSizeRange, step: 1, format: "%.0f")
                    }
                    sliderRow("Line Spacing", value: $draft.lineSpacing, commit: { lineSpacing = draft.lineSpacing }, range: TypographySettings.lineSpacingRange, step: 1, format: "%.0f")
                    sliderRow("Furigana Spacing", info: "The gap between the furigana and the word under it.", value: $draft.furiganaGap, commit: { furiganaGap = draft.furiganaGap }, range: TypographySettings.furiganaGapRange, step: 0.5, format: "%.1f")
                    sliderRow("Kerning", info: "Extra space between the characters of the text.", value: $draft.kerning, commit: { kerning = draft.kerning }, range: TypographySettings.kerningRange, step: 1, format: "%.1f")
                }
            }
            .scrollContentBackground(.hidden)
            .washiBackground()
            .onAppear {
                draft = TypographyDraft(
                    textSize: textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    furiganaGap: furiganaGap,
                    furiganaSize: furiganaSize
                )
            }
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
    // `info`, when given, adds an ⓘ popover after the title.
    private func sliderRow(
        _ title: String,
        info: String? = nil,
        value: Binding<Double>,
        commit: @escaping () -> Void,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                if let info {
                    InfoButton(text: info)
                }
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step) { editing in
                if editing == false { commit() }
            }
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
                    draft.furiganaSize = furiganaSize
                }
                customFuriganaSizeEnabled = !isAuto
            }
        )
    }
}
