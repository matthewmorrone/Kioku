import SwiftUI

// Renders the accent ring around the tour's cutout: a solid outline on the cutout's edge plus a
// second ring that keeps swelling outward and fading, so the eye lands on the target at once.
struct TourHighlightRing: View {
    let cornerRadius: CGFloat
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.accentColor, lineWidth: 3)
                .shadow(color: Color.accentColor.opacity(0.8), radius: 6)
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.accentColor, lineWidth: 2)
                .scaleEffect(isPulsing ? 1.25 : 1)
                .opacity(isPulsing ? 0 : 0.9)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}
