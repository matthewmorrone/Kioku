import SwiftUI

// A comic-style speech bubble: a rounded body (`body`) with a tapering tail running all the way to
// `tip`, the point on the word it's about. The tail leaves the body from the edge facing the tip,
// at the point on that edge nearest the tip (kept clear of the corners), and its sides bow
// slightly so it reads as one drawn shape; the sides taper only gently so the tail stays bold all the way to the tip. Drawn in the frame it's given, which must contain both.
nonisolated struct PointerBubbleShape: Shape {
    var body: CGRect
    var tip: CGPoint
    var cornerRadius: CGFloat = 14
    var baseHalfWidth: CGFloat = 10

    // Animates the body and the tip together as the bubble moves.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(AnimatablePair(tip.x, tip.y),
                           AnimatablePair(AnimatablePair(body.minX, body.minY), AnimatablePair(body.width, body.height)))
        }
        set {
            tip = CGPoint(x: newValue.first.first, y: newValue.first.second)
            body = CGRect(x: newValue.second.first.first, y: newValue.second.first.second,
                          width: newValue.second.second.first, height: newValue.second.second.second)
        }
    }

    // The body plus the tail wedge, as one filled outline.
    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, body.height / 2, body.width / 2)
        var path = Path(roundedRect: body, cornerRadius: radius)
        guard body.contains(tip) == false else { return path }
        // Wide enough to read as an arrow even on a one-line bubble: the base may overlap the rounded
        // corners, since it starts a little inside the body.
        let half = min(baseHalfWidth, max(3, min(body.width, body.height) / 2 - 3))
        // The tail's two base points on the edge facing the tip, a little inside the body so the
        // seam doesn't show.
        let base1: CGPoint
        let base2: CGPoint
        if tip.x > body.maxX || tip.x < body.minX, tip.y >= body.minY - 4, tip.y <= body.maxY + 4 {
            let x = tip.x > body.maxX ? body.maxX - 1 : body.minX + 1
            let y = min(max(tip.y, body.minY + half + 2), body.maxY - half - 2)
            base1 = CGPoint(x: x, y: y - half)
            base2 = CGPoint(x: x, y: y + half)
        } else {
            let y = tip.y > body.maxY ? body.maxY - 1 : body.minY + 1
            let x = min(max(tip.x, body.minX + half + 2), body.maxX - half - 2)
            base1 = CGPoint(x: x - half, y: y)
            base2 = CGPoint(x: x + half, y: y)
        }
        // Each side bows toward the other's base, tapering the tail.
        func bowed(from base: CGPoint, toward other: CGPoint) -> CGPoint {
            let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
            return CGPoint(x: mid.x + (other.x - base.x) * 0.1, y: mid.y + (other.y - base.y) * 0.1)
        }
        path.move(to: base1)
        path.addQuadCurve(to: tip, control: bowed(from: base1, toward: base2))
        path.addQuadCurve(to: base2, control: bowed(from: base2, toward: base1))
        path.closeSubpath()
        return path
    }
}
