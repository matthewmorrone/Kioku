import SwiftUI

// Theme-section helpers carved out of SettingsView so the main file stays under the 1000-line
// build-time invariant. Contains: the Menu replacement for the Theme picker (Picker labels
// don't honor `.tint()` on iOS 26), the Custom Theme toggle + four override pickers, the
// Custom Token Colors toggle + three override pickers, and the hex↔Color bindings the four
// Custom Theme pickers need.
extension SettingsView {

    // Menu replacement for SwiftUI's Form Picker — iOS 26's Picker won't honor `.tint()` for
    // its collapsed selection-label color even when the toggle right below honors it perfectly.
    // A Menu with an explicit label lets us style the active selection text with the active
    // theme's accent. Re-resolving `Theme.activePalette` at body-time means a custom-accent
    // change flows into the label too.
    @ViewBuilder
    var themePickerMenu: some View {
        let activeID = Theme.ID(rawValue: themeIDRaw) ?? .system
        let activeAccent = Color(Theme.activePalette.uiAccent)
        Menu {
            ForEach(Theme.ID.allCases) { id in
                Button {
                    themeIDRaw = id.rawValue
                } label: {
                    if id == activeID {
                        Label(id.displayName, systemImage: "checkmark")
                    } else {
                        Text(id.displayName)
                    }
                }
            }
        } label: {
            HStack {
                Text("Theme").foregroundStyle(.primary)
                Spacer()
                Text(activeID.displayName).foregroundStyle(activeAccent)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        // Re-runs UIKit appearance proxies on every theme change so newly-pushed bars adopt
        // the new chrome immediately. `setActive` also mirrors the legacy boolean.
        .onChange(of: themeIDRaw) { _, newValue in
            let id = Theme.ID(rawValue: newValue) ?? .system
            Theme.setActive(id)
        }
    }

    // Custom Theme toggle + four override pickers. Flipping the toggle on seeds the four hexes
    // from the currently-selected base theme so the user starts from the look they were just
    // viewing rather than blank hexes.
    @ViewBuilder
    var customThemeRows: some View {
        Toggle("Custom Theme", isOn: $customThemeEnabled)
            .onChange(of: customThemeEnabled) { oldValue, newValue in
                guard !oldValue, newValue else { return }
                let id = Theme.ID(rawValue: themeIDRaw) ?? .system
                let base = Theme.Palette.palette(for: id)
                customBackgroundHex = base.uiBackground.hexString ?? ""
                customSurfaceHex = base.uiSurface.hexString ?? ""
                customInkHex = base.uiInk.hexString ?? ""
                customAccentHex = base.uiAccent.hexString ?? ""
                Theme.refreshGlobalAppearance()
            }
        if customThemeEnabled {
            ColorPicker("Background", selection: customBackgroundBinding, supportsOpacity: false)
            ColorPicker("Surface", selection: customSurfaceBinding, supportsOpacity: false)
            ColorPicker("Text", selection: customInkBinding, supportsOpacity: false)
            ColorPicker("Accent", selection: customAccentBinding, supportsOpacity: false)
        }
    }

    // Custom Token Colors toggle + three override pickers — independent from Custom Theme.
    // The Read view's toolbar still owns the master alternation on/off; this is just for the
    // color hexes used when alternation is on.
    @ViewBuilder
    var customTokenColorRows: some View {
        Toggle("Custom Token Colors", isOn: $customTokenColorsEnabled)
            .onChange(of: customTokenColorsEnabled) { oldValue, newValue in
                guard !oldValue, newValue else { return }
                let palette = Theme.activePalette
                tokenColorAHex = palette.defaultTokenColorAHex
                tokenColorBHex = palette.defaultTokenColorBHex
                highlightHex = palette.defaultHighlightHex
            }
        if customTokenColorsEnabled {
            ColorPicker("Primary Color", selection: tokenColorABinding, supportsOpacity: false)
            ColorPicker("Secondary Color", selection: tokenColorBBinding, supportsOpacity: false)
            ColorPicker("Highlight Color", selection: tokenHighlightBinding, supportsOpacity: false)
        }
    }

    // Custom-theme color bindings: hex AppStorage <-> SwiftUI Color, with a fall-through to
    // the active base theme's color when the stored hex is empty or unparseable. The
    // background / ink / accent setters also call `refreshGlobalAppearance` so the UIKit nav
    // and tab bar chrome immediately picks up the new color on newly-pushed screens. Surface
    // is SwiftUI-only and doesn't reach UIKit chrome, so its setter skips the refresh.
    var customBackgroundBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: customBackgroundHex) ?? Theme.Palette.palette(for: Theme.ID(rawValue: themeIDRaw) ?? .system).uiBackground) },
            set: { if let hex = UIColor($0).hexString { customBackgroundHex = hex; Theme.refreshGlobalAppearance() } }
        )
    }
    var customSurfaceBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: customSurfaceHex) ?? Theme.Palette.palette(for: Theme.ID(rawValue: themeIDRaw) ?? .system).uiSurface) },
            set: { if let hex = UIColor($0).hexString { customSurfaceHex = hex } }
        )
    }
    var customInkBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: customInkHex) ?? Theme.Palette.palette(for: Theme.ID(rawValue: themeIDRaw) ?? .system).uiInk) },
            set: { if let hex = UIColor($0).hexString { customInkHex = hex; Theme.refreshGlobalAppearance() } }
        )
    }
    var customAccentBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: customAccentHex) ?? Theme.Palette.palette(for: Theme.ID(rawValue: themeIDRaw) ?? .system).uiAccent) },
            set: { if let hex = UIColor($0).hexString { customAccentHex = hex; Theme.refreshGlobalAppearance() } }
        )
    }
}
