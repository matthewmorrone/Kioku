import SwiftUI

// The triangular pointer joining the tour callout to its target. Drawn pointing up; the overlay
// flips it when the callout sits above the target.
nonisolated struct TourCalloutArrow: Shape {
    // Triangle with its tip at the top centre of the rect.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
