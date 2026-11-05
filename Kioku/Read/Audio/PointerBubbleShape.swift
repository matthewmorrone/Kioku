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

    // Where a tail from `body` to `tip` is rooted: its two base points, a little inside the body so
    // the seam doesn't show, and `edge`, the middle of where it leaves the body's edge. Nil when the
    // tip is inside the body. The layouts use it too, to keep tails from crossing.
    static func tailRoot(body: CGRect, tip: CGPoint, cornerRadius: CGFloat = 14, baseHalfWidth: CGFloat = 10) -> (base1: CGPoint, base2: CGPoint, edge: CGPoint)? {
        guard body.contains(tip) == false else { return nil }
        // Wide enough to read as an arrow even on a one-line bubble.
        let half = min(baseHalfWidth, max(3, min(body.height, body.width) / 2 - 3))
        // The base points sit well inside the body, and clear of the rounded corners, so the wedge
        // always overlaps solid body and never leaves a gap or a sliver (which showed as a detached
        // tail, or as a dark line from the shadow) where the corner curves away from the edge.
        let radius = min(cornerRadius, body.height / 2, body.width / 2)
        let inset: CGFloat = 4
        // Where along an edge of `length` starting at `origin` the tail may be centred: at `target`,
        // kept `radius + half` from the ends, or the middle when the edge is too short for that.
        func along(_ target: CGFloat, origin: CGFloat, length: CGFloat) -> CGFloat {
            let margin = radius + half
            guard length > 2 * margin else { return origin + length / 2 }
            return min(max(target, origin + margin), origin + length - margin)
        }
        if tip.x > body.maxX || tip.x < body.minX, tip.y >= body.minY - 4, tip.y <= body.maxY + 4 {
            let toRight = tip.x > body.maxX
            let x = toRight ? body.maxX - inset : body.minX + inset
            let y = along(tip.y, origin: body.minY, length: body.height)
            return (CGPoint(x: x, y: y - half), CGPoint(x: x, y: y + half), CGPoint(x: toRight ? body.maxX : body.minX, y: y))
        }
        let below = tip.y > body.maxY
        let y = below ? body.maxY - inset : body.minY + inset
        let x = along(tip.x, origin: body.minX, length: body.width)
        return (CGPoint(x: x - half, y: y), CGPoint(x: x + half, y: y), CGPoint(x: x, y: below ? body.maxY : body.minY))
    }

    // The body plus the tail wedge, as one filled outline (their union, so the overlap is solid).
    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, body.height / 2, body.width / 2)
        let bodyPath = Path(roundedRect: body, cornerRadius: radius)
        guard let root = Self.tailRoot(body: body, tip: tip, cornerRadius: cornerRadius, baseHalfWidth: baseHalfWidth) else { return bodyPath }
        let base1 = root.base1
        let base2 = root.base2
        // Each side bows toward the other's base, tapering the tail.
        func bowed(from base: CGPoint, toward other: CGPoint) -> CGPoint {
            let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
            return CGPoint(x: mid.x + (other.x - base.x) * 0.1, y: mid.y + (other.y - base.y) * 0.1)
        }
        var wedge = Path()
        wedge.move(to: base1)
        wedge.addQuadCurve(to: tip, control: bowed(from: base1, toward: base2))
        wedge.addQuadCurve(to: base2, control: bowed(from: base2, toward: base1))
        wedge.closeSubpath()
        // A real union: the body and the wedge wind in opposite directions depending on which edge the
        // tail leaves, and filling them as two subpaths of one path left a hole where they overlap.
        return bodyPath.union(wedge)
    }
}
