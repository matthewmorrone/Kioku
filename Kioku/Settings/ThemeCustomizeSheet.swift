import SwiftUI

// Renders the Customize Colors sheet opened from the Settings theme section: the live text
// preview at the top, then an Interface section (Custom Colors toggle + background, surface,
// text and accent pickers) and a Text section (Custom Colors toggle + the two segment colors,
// the selection highlight, and the Saved / Learned / Not Learned highlights), each ending in a
// Reset to Theme button. With a toggle off that group follows the selected theme; turning it
// back on restores the earlier picks, and Reset sets every picker to the theme's color.
struct ThemeCustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Theme.themeIDKey) private var themeIDRaw: String = ThemeID.system.rawValue

    @AppStorage(Theme.customThemeEnabledKey) private var customThemeEnabled: Bool = false
    @AppStorage(Theme.customBackgroundHexKey) private var customBackgroundHex: String = ""
    @AppStorage(Theme.customSurfaceHexKey) private var customSurfaceHex: String = ""
    @AppStorage(Theme.customInkHexKey) private var customInkHex: String = ""
    @AppStorage(Theme.customAccentHexKey) private var customAccentHex: String = ""

    @AppStorage(TokenColorSettings.enabledKey) private var customTextColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage(TokenColorSettings.highlightColorKey) private var highlightHex: String = TokenColorSettings.defaultHighlightHex
    @AppStorage(TokenColorSettings.savedColorKey) private var savedHex: String = TokenColorSettings.defaultSavedHex
    @AppStorage(TokenColorSettings.savedLearnedColorKey) private var savedLearnedHex: String = TokenColorSettings.defaultSavedLearnedHex
    @AppStorage(TokenColorSettings.savedNotLearnedColorKey) private var savedNotLearnedHex: String = TokenColorSettings.defaultSavedNotLearnedHex

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TypographyPreview()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Toggle("Custom Colors", isOn: $customThemeEnabled)
                        .onChange(of: customThemeEnabled) { oldValue, newValue in
                            guard !oldValue, newValue else { return }
                            seedInterfaceColors(onlyUnset: true)
                        }
                    if customThemeEnabled {
                        ColorPicker("Background", selection: interfaceBinding($customBackgroundHex), supportsOpacity: false)
                        ColorPicker("Surface", selection: interfaceBinding($customSurfaceHex), supportsOpacity: false)
                        ColorPicker("Text", selection: interfaceBinding($customInkHex), supportsOpacity: false)
                        ColorPicker("Accent", selection: interfaceBinding($customAccentHex), supportsOpacity: false)
                        Button("Reset to Theme") { seedInterfaceColors(onlyUnset: false) }
                    }
                } header: {
                    Text("Interface")
                } footer: {
                    Text("Replace the theme's background, surface, text and accent colors with your own.")
                }
                Section {
                    Toggle("Custom Colors", isOn: $customTextColorsEnabled)
                        .onChange(of: customTextColorsEnabled) { oldValue, newValue in
                            guard !oldValue, newValue else { return }
                            seedTextColors(onlyUnset: true)
                        }
                    if customTextColorsEnabled {
                        ColorPicker("Primary", selection: textBinding($tokenColorAHex), supportsOpacity: false)
                        ColorPicker("Secondary", selection: textBinding($tokenColorBHex), supportsOpacity: false)
                        ColorPicker("Selection", selection: textBinding($highlightHex), supportsOpacity: false)
                        ColorPicker("Saved", selection: textBinding($savedHex), supportsOpacity: false)
                        ColorPicker("Learned", selection: textBinding($savedLearnedHex), supportsOpacity: false)
                        ColorPicker("Not Learned", selection: textBinding($savedNotLearnedHex), supportsOpacity: false)
                        Button("Reset to Theme") { seedTextColors(onlyUnset: false) }
                    }
                } header: {
                    Text("Text")
                } footer: {
                    Text("Primary and Secondary alternate from word to word to show where the text is split. Saved, Learned and Not Learned color the words you've saved.")
                }
            }
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

    // The selected theme's palette without custom overrides — what the pickers start from.
    private var basePalette: ThemePalette {
        ThemePalette.palette(for: ThemeID(rawValue: themeIDRaw) ?? .system)
    }

    // Copies the theme's four interface colors into the custom slots. Turning Custom Colors on
    // fills only slots never set, so earlier picks come back and a first use starts from the
    // theme's look; Reset overwrites all four.
    private func seedInterfaceColors(onlyUnset: Bool) {
        let base = basePalette
        fill(Theme.customBackgroundHexKey, $customBackgroundHex, with: base.uiBackground.hexString, onlyUnset: onlyUnset)
        fill(Theme.customSurfaceHexKey, $customSurfaceHex, with: base.uiSurface.hexString, onlyUnset: onlyUnset)
        fill(Theme.customInkHexKey, $customInkHex, with: base.uiInk.hexString, onlyUnset: onlyUnset)
        fill(Theme.customAccentHexKey, $customAccentHex, with: base.uiAccent.hexString, onlyUnset: onlyUnset)
        Theme.refreshGlobalAppearance()
    }

    // Same as seedInterfaceColors, for the six text colors.
    private func seedTextColors(onlyUnset: Bool) {
        let base = basePalette
        fill(TokenColorSettings.colorAKey, $tokenColorAHex, with: base.defaultTokenColorAHex, onlyUnset: onlyUnset)
        fill(TokenColorSettings.colorBKey, $tokenColorBHex, with: base.defaultTokenColorBHex, onlyUnset: onlyUnset)
        fill(TokenColorSettings.highlightColorKey, $highlightHex, with: base.defaultHighlightHex, onlyUnset: onlyUnset)
        fill(TokenColorSettings.savedColorKey, $savedHex, with: base.defaultSavedHex, onlyUnset: onlyUnset)
        fill(TokenColorSettings.savedLearnedColorKey, $savedLearnedHex, with: base.defaultSavedLearnedHex, onlyUnset: onlyUnset)
        fill(TokenColorSettings.savedNotLearnedColorKey, $savedNotLearnedHex, with: base.defaultSavedNotLearnedHex, onlyUnset: onlyUnset)
    }

    // Writes `hex` into one custom slot. With `onlyUnset`, a slot that already holds a stored,
    // non-empty value is left alone — checked against UserDefaults, since @AppStorage reports
    // its placeholder default for a key that was never written.
    private func fill(_ key: String, _ slot: Binding<String>, with hex: String?, onlyUnset: Bool) {
        guard let hex else { return }
        if onlyUnset, let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty { return }
        slot.wrappedValue = hex
    }

    // Hex AppStorage <-> Color for an interface picker. Setting one re-runs the UIKit
    // appearance proxies so nav and tab bars pick the change up.
    private func interfaceBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: hex.wrappedValue) ?? .gray) },
            set: {
                guard let value = UIColor($0).hexString else { return }
                hex.wrappedValue = value
                Theme.refreshGlobalAppearance()
            }
        )
    }

    // Hex AppStorage <-> Color for a text-color picker.
    private func textBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: hex.wrappedValue) ?? .gray) },
            set: { if let value = UIColor($0).hexString { hex.wrappedValue = value } }
        )
    }
}
