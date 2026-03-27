import UIKit

// Hex color utilities for storing and restoring UIColor values in UserDefaults.
extension UIColor {
    // Parses a CSS-style hex color string into a UIColor.
    // Accepts 6-character (#RRGGBB) and 8-character (#RRGGBBAA) formats with or without the leading hash.
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }

        guard hex.count == 6 || hex.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8)  & 0xFF) / 255
            b = CGFloat( value        & 0xFF) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8)  & 0xFF) / 255
            a = CGFloat( value        & 0xFF) / 255
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }

    // Returns a 6-character uppercase hex string for this color in the sRGB color space.
    // Returns nil when the color cannot be converted to sRGB components.
    var hexString: String? {
        guard let components = cgColor.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        )?.components, components.count >= 3 else { return nil }

        let r = Int(round(components[0] * 255))
        let g = Int(round(components[1] * 255))
        let b = Int(round(components[2] * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
