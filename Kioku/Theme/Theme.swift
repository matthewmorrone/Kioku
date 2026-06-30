import SwiftUI
import UIKit

// MARK: - Theme
//
// App-wide visual language, parameterized by a selectable theme id. Each theme bundles:
//   - a UI palette (background, surface, ink, accent, hairline)
//   - default token alternation colors A/B + highlight
//   - whether to install the Mincho UIKit appearance proxies
//
// Storage: the active id lives at `kioku.themeID`. The legacy `kioku.japaneseTheme` boolean
// is kept readable so existing users see no behavior change: `true` resolves to the Washi
// theme, `false` resolves to System. Writing a new id from the picker updates `kioku.themeID`
// and the legacy boolean follows along for any code path still reading it.
//
// UIColor is the single source of truth so the SwiftUI tokens (`Theme.ink`) and the UIKit
// appearance proxies draw from identical adaptive values; both light/dark traits are baked
// into every adaptive UIColor.
enum Theme {

    // MARK: Identity

    // Picker-backed identifier. `system` opts the app out of themed chrome entirely so the
    // UIKit appearance proxies are reset to defaults — i.e. it behaves like the pre-theme app.
    enum ID: String, CaseIterable, Identifiable, Sendable {
        case system
        case washi
        case sumi

        var id: String { rawValue }

        // Picker label. Short on purpose so the dropdown stays one line on narrow phones.
        var displayName: String {
            switch self {
            case .system: return "System"
            case .washi:  return "Washi"
            case .sumi:   return "Sumi"
            }
        }
    }

    // MARK: Storage

    // New canonical key — raw string of `ID`.
    static let themeIDKey = "kioku.themeID"
    // Legacy on/off key. Kept readable for backward compat: a user upgrading from the boolean
    // toggle sees the new picker preselected to Washi (their old setting) without an explicit
    // migration step. Also kept writable so any code path that hasn't moved over to the new
    // key still observes a sensible value (washi = true, anything else = false).
    static let storageKey = "kioku.japaneseTheme"

    // Custom theme overlay — when `customThemeEnabledKey` is true, the four custom hexes
    // override the active palette's background / surface / ink / accent. Other palette slots
    // (secondary ink, hairline, deep accent, token defaults) keep the active theme's values
    // — those second-tier slots aren't user-facing in Settings, and pinning them prevents the
    // customized palette from going incoherent if the user picks, say, a black ink against a
    // dark background and forgets to also adjust the secondary ink.
    static let customThemeEnabledKey = "kioku.customTheme.enabled"
    static let customBackgroundHexKey = "kioku.customTheme.backgroundHex"
    static let customSurfaceHexKey = "kioku.customTheme.surfaceHex"
    static let customInkHexKey = "kioku.customTheme.inkHex"
    static let customAccentHexKey = "kioku.customTheme.accentHex"

    // Reads the active id, with a one-line fall-through to the legacy boolean for users who
    // upgrade from before the picker existed. Pure read, no migration writes — keeps the
    // resolution stateless so a missing UserDefaults key never produces surprise writes.
    static var activeID: ID {
        if let raw = UserDefaults.standard.string(forKey: themeIDKey), let id = ID(rawValue: raw) {
            return id
        }
        return UserDefaults.standard.bool(forKey: storageKey) ? .washi : .system
    }

    // Mirrors the legacy boolean so non-View read sites that haven't moved to `activeID` yet
    // still get a sensible answer. Everything new should call `activeID` directly.
    static var isEnabled: Bool { activeID != .system }

    // MARK: Active palette

    // The palette of the currently-selected theme, with the user's custom hex overrides
    // applied when Custom Theme is on. Empty / unparseable hexes fall back to the base
    // theme's value, so a half-customized palette stays coherent.
    static var activePalette: Palette {
        let base = Palette.palette(for: activeID)
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: customThemeEnabledKey) else { return base }
        let bg = UIColor(hexString: defaults.string(forKey: customBackgroundHexKey) ?? "") ?? base.uiBackground
        let surface = UIColor(hexString: defaults.string(forKey: customSurfaceHexKey) ?? "") ?? base.uiSurface
        let ink = UIColor(hexString: defaults.string(forKey: customInkHexKey) ?? "") ?? base.uiInk
        let accent = UIColor(hexString: defaults.string(forKey: customAccentHexKey) ?? "") ?? base.uiAccent
        return Palette(
            uiBackground: bg,
            uiSurface: surface,
            uiSurfaceSecondary: base.uiSurfaceSecondary,
            uiInk: ink,
            uiInkSecondary: base.uiInkSecondary,
            uiAccent: accent,
            uiAccentDeep: base.uiAccentDeep,
            uiHairline: base.uiHairline,
            defaultTokenColorAHex: base.defaultTokenColorAHex,
            defaultTokenColorBHex: base.defaultTokenColorBHex,
            defaultHighlightHex: base.defaultHighlightHex,
            // Force-on so the nav/tab UIKit chrome adopts the user's overrides even when the
            // base theme is System (which normally skips the appearance proxies).
            installsCustomAppearance: true
        )
    }

    // MARK: Palette structure

    // Carries every adaptive UIColor + the default token hexes for one theme. UIColors are
    // already trait-aware (light/dark folded inside each); the struct itself is light/dark
    // agnostic. Built once per theme at compile time and stored in the registry below.
    struct Palette: Sendable {
        let uiBackground: UIColor
        let uiSurface: UIColor
        let uiSurfaceSecondary: UIColor
        let uiInk: UIColor
        let uiInkSecondary: UIColor
        let uiAccent: UIColor
        let uiAccentDeep: UIColor
        let uiHairline: UIColor
        // Default token alternation colors when the user hasn't enabled Custom Token Colors.
        // Hex strings (not UIColor) so existing render paths that parse from AppStorage keep
        // the same code shape — they just pull the seed string from here instead of the
        // hardcoded TokenColorSettings constants.
        let defaultTokenColorAHex: String
        let defaultTokenColorBHex: String
        let defaultHighlightHex: String
        // Whether to install Mincho UIKit title fonts / themed nav+tab chrome. The System
        // theme leaves these off so the app looks Apple-native.
        let installsCustomAppearance: Bool

        // Factory: returns the palette for a given id. Plain switch instead of a dictionary
        // so each branch can directly call the per-theme builder below.
        static func palette(for id: ID) -> Palette {
            switch id {
            case .system: return systemPalette
            case .washi:  return washiPalette
            case .sumi:   return sumiPalette
            }
        }
    }

    // MARK: Adaptive color helper

    // Builds an adaptive color from a light and a dark RGB triple (0–255 components).
    private static func adaptive(
        light: (r: Double, g: Double, b: Double),
        dark: (r: Double, g: Double, b: Double)
    ) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
        }
    }

    // MARK: System theme

    // Pure-system-color palette: every "ui*" prop resolves to the matching UIColor.systemX so
    // a view that draws Theme.background looks identical to one drawing Color(.systemBackground).
    // Token defaults are vivid iOS-system colors (blue/pink/green) — deliberately cool and
    // high-saturation so they don't read as a sibling of Washi's warm earth tones or Sumi's
    // muted plum/sage/gold. Each pair has strong contrast against the other two themes.
    static let systemPalette = Palette(
        uiBackground: .systemBackground,
        uiSurface: .secondarySystemBackground,
        uiSurfaceSecondary: .tertiarySystemBackground,
        uiInk: .label,
        uiInkSecondary: .secondaryLabel,
        uiAccent: .systemBlue,
        uiAccentDeep: UIColor { tc in tc.userInterfaceStyle == .dark ? .systemTeal : .systemIndigo },
        uiHairline: .separator,
        defaultTokenColorAHex: "#007AFF",  // iOS systemBlue — bright digital primary
        defaultTokenColorBHex: "#FF2D55",  // iOS systemPink — saturated, far from Sumi plum
        defaultHighlightHex: "#30D158",    // iOS systemGreen — vivid, distinct from Washi amber + Sumi sage
        installsCustomAppearance: false
    )

    // MARK: Washi theme (formerly "Japanese Theme")

    // Warm kinari paper canvas in light, deep warm sumi in dark, single vermilion accent.
    // Token defaults shift toward sepia + ink-blue so segment alternation reads against the
    // paper rather than fighting the vermilion chrome.
    static let washiPalette = Palette(
        uiBackground: adaptive(light: (245, 241, 232), dark: (21, 19, 14)),
        uiSurface: adaptive(light: (255, 253, 248), dark: (33, 30, 24)),
        uiSurfaceSecondary: adaptive(light: (251, 248, 241), dark: (42, 38, 32)),
        uiInk: adaptive(light: (33, 28, 22), dark: (236, 228, 214)),
        uiInkSecondary: adaptive(light: (110, 101, 90), dark: (168, 155, 137)),
        uiAccent: adaptive(light: (199, 54, 59), dark: (219, 90, 78)),
        uiAccentDeep: adaptive(light: (158, 43, 43), dark: (199, 54, 59)),
        uiHairline: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : UIColor(red: 158 / 255, green: 138 / 255, blue: 116 / 255, alpha: 0.28)
        },
        // Warm sepia + muted indigo read crisply against warm paper without clashing with the
        // vermilion accent. Highlight is a soft amber that finishes the triad.
        defaultTokenColorAHex: "#A14B2F",
        defaultTokenColorBHex: "#3B5F8A",
        defaultHighlightHex: "#E6B23A",
        installsCustomAppearance: true
    )

    // MARK: Sumi theme

    // Ink-on-charcoal: a more graphic, monochrome-leaning take on the washi aesthetic with a
    // single muted gold accent instead of vermilion. Distinct from system dark mode because
    // of the warm sumi ink (never cold gray) and the gold highlight rule on themed cards.
    static let sumiPalette = Palette(
        uiBackground: adaptive(light: (240, 236, 228), dark: (16, 15, 12)),
        uiSurface: adaptive(light: (250, 247, 240), dark: (28, 26, 22)),
        uiSurfaceSecondary: adaptive(light: (246, 242, 233), dark: (40, 36, 30)),
        uiInk: adaptive(light: (22, 19, 14), dark: (240, 232, 218)),
        uiInkSecondary: adaptive(light: (95, 86, 74), dark: (172, 160, 142)),
        uiAccent: adaptive(light: (146, 110, 36), dark: (212, 174, 92)),
        uiAccentDeep: adaptive(light: (108, 80, 22), dark: (170, 138, 66)),
        uiHairline: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.08)
                : UIColor(red: 120 / 255, green: 108 / 255, blue: 90 / 255, alpha: 0.22)
        },
        // Muted plum + sage — quiet, low-saturation pair that suits the ink aesthetic.
        // Highlight is the same muted gold as the accent so the glow reads as theme-coordinated.
        defaultTokenColorAHex: "#8E4F6F",
        defaultTokenColorBHex: "#4F7A57",
        defaultHighlightHex: "#D4AE5C",
        installsCustomAppearance: true
    )

    // MARK: Palette (UIColor properties — delegate to active palette)

    static var uiBackground: UIColor { activePalette.uiBackground }
    static var uiSurface: UIColor { activePalette.uiSurface }
    static var uiSurfaceSecondary: UIColor { activePalette.uiSurfaceSecondary }
    static var uiInk: UIColor { activePalette.uiInk }
    static var uiInkSecondary: UIColor { activePalette.uiInkSecondary }
    static var uiAccent: UIColor { activePalette.uiAccent }
    static var uiAccentDeep: UIColor { activePalette.uiAccentDeep }
    static var uiHairline: UIColor { activePalette.uiHairline }

    // MARK: Palette (SwiftUI tokens — also resolve at access)

    static var background: Color { Color(uiBackground) }
    static var surface: Color { Color(uiSurface) }
    static var surfaceSecondary: Color { Color(uiSurfaceSecondary) }
    static var ink: Color { Color(uiInk) }
    static var inkSecondary: Color { Color(uiInkSecondary) }
    static var accent: Color { Color(uiAccent) }
    static var accentDeep: Color { Color(uiAccentDeep) }
    static var hairline: Color { Color(uiHairline) }

    // MARK: Metrics

    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 16

    // MARK: Global appearance

    // Installs UIKit appearance proxies for the active theme. Called once at launch from
    // `KiokuApp.init` and again any time the picker changes. The System theme path resets the
    // chrome instead of installing custom proxies.
    static func applyGlobalAppearance() {
        guard activePalette.installsCustomAppearance else { resetGlobalAppearance(); return }

        // Mincho title fonts. Hiragino Mincho ships with iOS, so no bundled font is required.
        let titleFont = UIFont(name: "HiraMinProN-W6", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        let largeTitleFont = UIFont(name: "HiraMinProN-W6", size: 32) ?? .systemFont(ofSize: 32, weight: .bold)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiBackground
        nav.shadowColor = uiHairline
        nav.titleTextAttributes = [.foregroundColor: uiInk, .font: titleFont]
        nav.largeTitleTextAttributes = [.foregroundColor: uiInk, .font: largeTitleFont]

        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = uiAccent

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiBackground
        tab.shadowColor = uiHairline

        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = uiAccent
    }

    // Restores the system default nav/tab bar appearance. Newly created bars pick this up
    // immediately; bars already on screen refresh on the next push or relaunch (UIKit
    // appearance proxies only apply at bar-creation time).
    static func resetGlobalAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nil
        UINavigationBar.appearance().tintColor = nil

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = nil
    }

    // Picker-side hook: rewrite both the new id key and the legacy boolean (so any non-View
    // reader that still consults the boolean stays in sync), then reapply the chrome.
    static func setActive(_ id: ID) {
        UserDefaults.standard.set(id.rawValue, forKey: themeIDKey)
        UserDefaults.standard.set(id != .system, forKey: storageKey)
        applyGlobalAppearance()
    }

    // Applies or resets the global chrome based on the current selection. Call at launch and
    // whenever the picker changes.
    static func refreshGlobalAppearance() {
        applyGlobalAppearance()
    }
}

// MARK: - Typography
//
// Display type is Hiragino Mincho (明朝体) — the serif-like brush style of printed Japanese
// books — sized relative to a Dynamic Type text style so it still scales with accessibility
// settings. English glosses use the system serif so they sit harmoniously beside the Mincho.
extension Font {
    // Bold Mincho for headers and Japanese headwords. `relativeTo` preserves Dynamic Type scaling.
    static func jpDisplay(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("HiraMinProN-W6", size: size, relativeTo: style)
    }

    // Light Mincho for Japanese readings and softer secondary Japanese text.
    static func jpReading(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("HiraMinProN-W3", size: size, relativeTo: style)
    }

    // System serif for English meanings, keeping tonal kinship with the Mincho display face.
    static func enSerif(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }
}

// MARK: - View modifiers

// Paints the active theme's canvas behind a scrollable container (List/Form/ScrollView) and
// hides the default system grouped background. Re-reads `Theme.activeID` on every recompose
// so a picker change updates the canvas live.
private struct WashiBackground: ViewModifier {
    // Observe every key that contributes to the resolved canvas color so a change to any of
    // them triggers a re-render. SwiftUI only tracks the specific @AppStorage properties it
    // sees referenced; `Theme.background` reads UserDefaults directly under the hood, so we
    // need explicit observers here to make those reads trigger view updates.
    @AppStorage(Theme.themeIDKey) private var themeID: String = Theme.ID.system.rawValue
    @AppStorage(Theme.customThemeEnabledKey) private var customEnabled: Bool = false
    @AppStorage(Theme.customBackgroundHexKey) private var customBackgroundHex: String = ""

    // Always applies the same modifier chain regardless of theme so the view-tree shape stays
    // stable — only the resolved values flip. Painting `Color(.systemGroupedBackground)` when
    // the System theme is selected without overrides keeps Settings looking native; otherwise
    // the active palette's background shows through.
    func body(content: Content) -> some View {
        let id = Theme.ID(rawValue: themeID) ?? .system
        let usesSystemCanvas = id == .system && !customEnabled
        content
            .scrollContentBackground(.hidden)
            .background(
                (usesSystemCanvas ? Color(.systemGroupedBackground) : Theme.background)
                    .ignoresSafeArea()
            )
    }
}

// Applies the active theme's accent app-wide, and falls back to the system accent (nil tint)
// when the System theme is selected.
private struct ThemedTint: ViewModifier {
    // Observe both the theme id and the custom-theme keys so a custom-accent change forces a
    // re-render. Without the custom-enabled / custom-accent observers, a user picking a new
    // accent hex would update UserDefaults but the modifier wouldn't re-tint.
    @AppStorage(Theme.themeIDKey) private var themeID: String = Theme.ID.system.rawValue
    @AppStorage(Theme.customThemeEnabledKey) private var customEnabled: Bool = false
    @AppStorage(Theme.customAccentHexKey) private var customAccentHex: String = ""

    // Always apply the active palette's accent — even for the System theme, where it
    // resolves to systemBlue. iOS otherwise defaults switches to systemGreen and menus /
    // pickers to systemBlue, so a "no tint" path produces a mismatched mix of green and
    // blue controls inside the same screen. Pinning the tint here keeps every Form control
    // on the same color regardless of which theme is active.
    func body(content: Content) -> some View {
        content.tint(Theme.accent)
    }
}

// A refined paper card: surface fill, hairline border, soft warm shadow, and a thin accent
// rule along the top edge echoing the masthead rule of Japanese letterhead (便箋).
private struct ThemedCard: ViewModifier {
    var topRule: Bool = true
    // Composes the surface fill, optional accent top rule, hairline border, and warm shadow.
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(alignment: .top) {
                        if topRule {
                            Theme.accent.opacity(0.85).frame(height: 3)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)
    }
}

extension View {
    // Opts a scrollable container into the active theme's canvas (no-op when System is selected).
    func washiBackground() -> some View { modifier(WashiBackground()) }

    // Applies the active theme's accent app-wide, gated on the picker.
    func themedTint() -> some View { modifier(ThemedTint()) }

    // Wraps content in a refined paper card (see `ThemedCard`).
    func themedCard(topRule: Bool = true) -> some View { modifier(ThemedCard(topRule: topRule)) }
}
