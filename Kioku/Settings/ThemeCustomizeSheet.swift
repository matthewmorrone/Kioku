import SwiftUI

// Renders the Customize Colors sheet opened from the Settings theme section: the live text
// preview at the top, then an Interface section (Custom Colors toggle + background, surface,
// text and accent pickers) and a Text section (Custom Colors toggle + the two segment colors,
// the selection highlight, and the Saved / Learned / Not Learned highlights), each ending in a
// Reset to Theme button. With a toggle off that group follows the selected theme; turning it
// on, or pressing Reset, sets every picker to the theme's color.
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
                            seedInterfaceColors()
                        }
                    if customThemeEnabled {
                        ColorPicker("Background", selection: interfaceBinding($customBackgroundHex), supportsOpacity: false)
                        ColorPicker("Surface", selection: interfaceBinding($customSurfaceHex), supportsOpacity: false)
                        ColorPicker("Text", selection: interfaceBinding($customInkHex), supportsOpacity: false)
                        ColorPicker("Accent", selection: interfaceBinding($customAccentHex), supportsOpacity: false)
                        Button("Reset to Theme") { seedInterfaceColors() }
                    }
                } header: {
                    Text("Interface")
                }
                Section {
                    Toggle("Custom Colors", isOn: $customTextColorsEnabled)
                        .onChange(of: customTextColorsEnabled) { oldValue, newValue in
                            guard !oldValue, newValue else { return }
                            seedTextColors()
                        }
                    if customTextColorsEnabled {
                        ColorPicker("Primary", selection: textBinding($tokenColorAHex), supportsOpacity: false)
                        ColorPicker("Secondary", selection: textBinding($tokenColorBHex), supportsOpacity: false)
                        ColorPicker("Selection", selection: textBinding($highlightHex), supportsOpacity: false)
                        ColorPicker("Saved", selection: textBinding($savedHex), supportsOpacity: false)
                        ColorPicker("Learned", selection: textBinding($savedLearnedHex), supportsOpacity: false)
                        ColorPicker("Not Learned", selection: textBinding($savedNotLearnedHex), supportsOpacity: false)
                        Button("Reset to Theme") { seedTextColors() }
                    }
                } header: {
                    Text("Text")
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

    // Copies the theme's four interface colors into the custom slots — so turning Custom Colors
    // on changes nothing until a picker moves, and Reset returns to the theme's look.
    private func seedInterfaceColors() {
        let base = basePalette
        customBackgroundHex = base.uiBackground.hexString ?? ""
        customSurfaceHex = base.uiSurface.hexString ?? ""
        customInkHex = base.uiInk.hexString ?? ""
        customAccentHex = base.uiAccent.hexString ?? ""
        Theme.refreshGlobalAppearance()
    }

    // Copies the theme's six text colors into the custom slots, for the same reason.
    private func seedTextColors() {
        let base = basePalette
        tokenColorAHex = base.defaultTokenColorAHex
        tokenColorBHex = base.defaultTokenColorBHex
        highlightHex = base.defaultHighlightHex
        savedHex = base.defaultSavedHex
        savedLearnedHex = base.defaultSavedLearnedHex
        savedNotLearnedHex = base.defaultSavedNotLearnedHex
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
