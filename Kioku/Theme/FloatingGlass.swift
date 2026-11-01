import SwiftUI

// The surface for things that float over content — banners, the page-dots pill, the mini player.
// On iOS 26 it is Liquid Glass, which brings its own edge and depth; earlier systems get the thin
// material the app has always used, with the hairline and shadow those surfaces carried before.
struct FloatingGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    // Width of the separator hairline drawn around the pre-iOS 26 material; nil draws none.
    let hairline: CGFloat?
    // Opacity of the pre-iOS 26 drop shadow; 0 draws none.
    let shadowOpacity: Double

    // Applies Liquid Glass where available, the material fallback elsewhere.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .overlay {
                    if let hairline { shape.stroke(Color(.separator), lineWidth: hairline) }
                }
                .shadow(color: .black.opacity(shadowOpacity), radius: 14, x: 0, y: 4)
        }
    }
}

extension View {
    // Renders this view on a floating glass surface of the given shape (see FloatingGlassModifier).
    func floatingGlass<S: InsettableShape>(in shape: S, hairline: CGFloat? = nil, shadowOpacity: Double = 0) -> some View {
        modifier(FloatingGlassModifier(shape: shape, hairline: hairline, shadowOpacity: shadowOpacity))
    }
}
