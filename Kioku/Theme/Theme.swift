import SwiftUI
import UIKit

// MARK: - Theme
//
// The app-wide visual language: a refined Japanese aesthetic built on washi (和紙, handmade
// paper) tones in light mode and sumi (墨, ink) tones in dark mode, accented by a single
// vermilion red (朱色) and set in Hiragino Mincho (明朝体) for display type.
//
// UIColor is the single source of truth so the SwiftUI tokens (`Theme.ink`) and the UIKit
// appearance proxies (nav bar / tab bar, configured in `applyGlobalAppearance`) draw from the
// exact same adaptive values. Every color resolves per-trait via `UIColor { traits in ... }`,
// so light/dark switches automatically with the system.
enum Theme {

    // MARK: Opt-in

    // UserDefaults/@AppStorage key backing the "Japanese Theme" toggle in Settings. The theme is
    // opt-in: when this is false (the default), every themed surface falls back to the system look,
    // so the app appears exactly as it did before the theme existed.
    static let storageKey = "kioku.japaneseTheme"

    // Non-View read of the toggle, for launch-time / UIKit contexts (e.g. `KiokuApp.init`).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    // MARK: Palette (UIColor source of truth)

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

    // The app canvas. Warm kinari (生成り) paper in light; deep warm sumi in dark.
    static let uiBackground = adaptive(light: (245, 241, 232), dark: (21, 19, 14))
    // Raised surfaces — cards, sheets, grouped rows. A shade lighter/cleaner than the canvas.
    static let uiSurface = adaptive(light: (255, 253, 248), dark: (33, 30, 24))
    // Secondary raised surface for nested rows and inset groups.
    static let uiSurfaceSecondary = adaptive(light: (251, 248, 241), dark: (42, 38, 32))
    // Primary text — warm near-black sumi, never a cold pure black.
    static let uiInk = adaptive(light: (33, 28, 22), dark: (236, 228, 214))
    // Secondary text — muted warm gray for captions, readings, metadata.
    static let uiInkSecondary = adaptive(light: (110, 101, 90), dark: (168, 155, 137))
    // The accent: vermilion 朱色. Slightly brighter in dark so it keeps contrast on the ink canvas.
    static let uiAccent = adaptive(light: (199, 54, 59), dark: (219, 90, 78))
    // Deeper crimson 紅 for pressed states and secondary accents.
    static let uiAccentDeep = adaptive(light: (158, 43, 43), dark: (199, 54, 59))
    // Hairline borders and dividers — warm sepia in light, faint white in dark.
    static let uiHairline = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(red: 158 / 255, green: 138 / 255, blue: 116 / 255, alpha: 0.28)
    }

    // MARK: Palette (SwiftUI tokens)

    static let background = Color(uiBackground)
    static let surface = Color(uiSurface)
    static let surfaceSecondary = Color(uiSurfaceSecondary)
    static let ink = Color(uiInk)
    static let inkSecondary = Color(uiInkSecondary)
    static let accent = Color(uiAccent)
    static let accentDeep = Color(uiAccentDeep)
    static let hairline = Color(uiHairline)

    // MARK: Metrics

    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 16

    // MARK: Global appearance

    // Installs UIKit appearance proxies so navigation bars and tab bars adopt the paper canvas
    // and Mincho titles app-wide. Called once at launch from `KiokuApp.init`. SwiftUI screens
    // additionally opt their Lists/Forms into the paper canvas via `.washiBackground()`.
    static func applyGlobalAppearance() {
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

    // Restores the system default nav/tab bar appearance when the theme is turned off. Newly
    // created bars pick this up immediately; bars already on screen refresh on the next push or
    // relaunch (UIKit appearance proxies only apply at bar-creation time).
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

    // Applies or resets the global chrome based on the current toggle. Call at launch and whenever
    // the toggle changes.
    static func refreshGlobalAppearance() {
        if isEnabled { applyGlobalAppearance() } else { resetGlobalAppearance() }
    }
}

// MARK: - Typography
//
// Display type is Hiragina Mincho (明朝体) — the serif-like brush style of printed Japanese
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

// Paints the washi paper canvas behind a scrollable container (List/Form/ScrollView) and hides
// the default system grouped background so the warm tone shows through.
private struct WashiBackground: ViewModifier {
    // Reactive to the toggle: when the theme is off this is a no-op, so the container keeps its
    // default system background and the screen looks exactly as it did before the theme.
    @AppStorage(Theme.storageKey) private var enabled = false
    // Hides the system container background and lays the paper canvas behind the content.
    func body(content: Content) -> some View {
        if enabled {
            content
                .scrollContentBackground(.hidden)
                .background(Theme.background.ignoresSafeArea())
        } else {
            content
        }
    }
}

// Applies the vermilion accent app-wide when the theme is on, and falls back to the system accent
// (nil tint) when off. Used in place of a bare `.tint()` so the toggle drives it live.
private struct ThemedTint: ViewModifier {
    @AppStorage(Theme.storageKey) private var enabled = false
    // Sets the vermilion tint when enabled, otherwise clears it back to the system default.
    func body(content: Content) -> some View {
        content.tint(enabled ? Theme.accent : nil)
    }
}

// A refined paper card: surface fill, hairline border, soft warm shadow, and a thin vermilion
// rule along the top edge echoing the masthead rule of Japanese letterhead (便箋).
private struct ThemedCard: ViewModifier {
    var topRule: Bool = true
    // Composes the surface fill, optional vermilion top rule, hairline border, and warm shadow.
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
    // Opts a scrollable container into the warm paper canvas (no-op when the theme is off).
    func washiBackground() -> some View { modifier(WashiBackground()) }

    // Applies the vermilion accent app-wide, gated on the theme toggle.
    func themedTint() -> some View { modifier(ThemedTint()) }

    // Wraps content in a refined paper card (see `ThemedCard`).
    func themedCard(topRule: Bool = true) -> some View { modifier(ThemedCard(topRule: topRule)) }
}
