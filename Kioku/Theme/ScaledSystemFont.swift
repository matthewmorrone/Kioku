import SwiftUI

// A system font at a designed point size that still follows the user's Dynamic Type setting.
// `.font(.system(size:))` pins a size forever; this keeps the size a view was laid out at for the
// default text size and scales it the way the nearest built-in text style scales, so a 12 pt label
// grows like a caption and a 17 pt icon like body text.
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    // Picks the text style whose scaling curve matches the designed size.
    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(near: size))
        self.weight = weight
        self.design = design
    }

    // Applies the scaled size.
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }

    // Maps a point size to the built-in text style with the closest default size.
    private static func textStyle(near size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case ..<12.5: return .caption
        case ..<14: return .footnote
        case ..<15.5: return .subheadline
        case ..<16.5: return .callout
        case ..<18.5: return .body
        case ..<21: return .title3
        case ..<25: return .title2
        default: return .title
        }
    }
}

extension View {
    // Drop-in replacement for `.font(.system(size:weight:design:))` that scales with Dynamic Type.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }
}
