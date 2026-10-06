import SwiftUI
import UIKit

// The app's visual language, redeclared locally because Theme lives in the main app target and
// isn't shared with the extension: warm sumi/kinari canvas, vermilion 朱色 accent, Hiragino Mincho
// for Japanese, system serif for English. Colors adapt to light/dark like the app's palette.
enum WidgetTheme {
    // Builds a light/dark-adaptive color from two RGB triples (0–255), matching Theme.swift.
    static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }

    static let surface = adaptive(light: (255, 253, 248), dark: (33, 30, 24))
    static let ink = adaptive(light: (33, 28, 22), dark: (236, 228, 214))
    static let inkSecondary = adaptive(light: (110, 101, 90), dark: (168, 155, 137))
    static let vermilion = adaptive(light: (199, 54, 59), dark: (219, 90, 78))

    // Bold Hiragino Mincho for headwords; light for readings/labels. Both ship with iOS.
    static func mincho(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size)
    }

    // System serif for English glosses, keeping tonal kinship with the Mincho display face.
    static func serif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif)
    }
}
