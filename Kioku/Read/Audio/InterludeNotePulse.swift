import SwiftUI

// Scale/opacity/hop for one note: `loudness` (0…1, relative to the song) sets its resting size and
// how hard it kicks, `pulse` (1 on a beat, decaying) the kick itself. The kick and hop grow with
// loudness squared, so quiet passages stay small and calm and only the loudest parts go big.
struct InterludeNotePulse: ViewModifier {
    let pulse: Double
    let loudness: Double
    let fontSize: CGFloat

    // Applies this note's size, opacity and hop for the current beat pulse and loudness.
    func body(content: Content) -> some View {
        let drama: Double = loudness * loudness
        let restingScale: Double = 0.5 + loudness * 1.1
        let kick: Double = 0.08 + drama * 1.1
        let scale: Double = restingScale * (1.0 + pulse * kick)
        let opacity: Double = 0.5 + pulse * 0.5
        let hop: Double = -pulse * drama * Double(fontSize) * 0.7
        content
            .scaleEffect(scale)
            .offset(y: hop)
            .opacity(opacity)
    }
}
