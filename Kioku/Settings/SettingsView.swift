import SwiftUI

// Presents typography controls and a live preview for reading settings.
struct SettingsView: View {
    @AppStorage(TypographySettings.textSizeKey)
    private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey)
    private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey)
    private var kerning = TypographySettings.defaultKerning

    private let previewText = "情報処理技術者試験対策資料を精読し、概念理解を深める。"

    var body: some View {
        NavigationStack {
            Form {
                // Shows live typography preview content.
                Section {
                    RichTextPreview(
                        text: previewText,
                        textSize: textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning
                    )
                        .frame(minHeight: 96)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))
                        )
                } header: {
                    Text("Preview")
                }

                // Hosts typography sliders that update read and preview rendering.
                Section {
                    // Controls base font size.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(String(format: "%.0f", textSize))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $textSize, in: TypographySettings.textSizeRange, step: 1)
                    }

                    // Controls additional line spacing.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Spacing")
                            Spacer()
                            Text(String(format: "%.0f", lineSpacing))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $lineSpacing, in: TypographySettings.lineSpacingRange, step: 1)
                    }

                    // Controls character spacing.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Kerning")
                            Spacer()
                            Text(String(format: "%.1f", kerning))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $kerning, in: TypographySettings.kerningRange, step: 1)
                    }
                } header: {
                    Text("Typography")
                }
            }
            .navigationTitle("Settings")
        }
        .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .settings)
}
