import SwiftUI

// A rounded speech bubble with a small tail on one edge (`edge`), at `tailFraction` (0–1) along
// that edge, pointing toward the word it belongs to. The tail is drawn within the frame's
// `tailLength` on that edge; the body fills the rest.
nonisolated struct SpeechBubbleShape: Shape {
    var edge: Edge = .bottom
    var tailFraction: CGFloat
    var tailLength: CGFloat = 6
    var cornerRadius: CGFloat = 12

    // Animates the tail sliding along its edge as the bubble moves.
    var animatableData: CGFloat {
        get { tailFraction }
        set { tailFraction = newValue }
    }

    // The bubble body inset from the tail's edge, with the tail cut into that side.
    func path(in rect: CGRect) -> Path {
        var body = rect
        switch edge {
        case .bottom: body.size.height -= tailLength
        case .top: body.origin.y += tailLength; body.size.height -= tailLength
        case .leading: body.origin.x += tailLength; body.size.width -= tailLength
        case .trailing: body.size.width -= tailLength
        }
        let radius = min(cornerRadius, body.height / 2, body.width / 2)
        var path = Path(roundedRect: body, cornerRadius: radius)
        let halfBase: CGFloat = 5
        // The tail's base sits along the edge, kept clear of the rounded corners.
        func along(_ start: CGFloat, _ length: CGFloat) -> CGFloat {
            min(max(start + length * tailFraction, start + radius + halfBase), start + length - radius - halfBase)
        }
        switch edge {
        case .bottom:
            let x = along(body.minX, body.width)
            path.move(to: CGPoint(x: x - halfBase, y: body.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + halfBase, y: body.maxY))
        case .top:
            let x = along(body.minX, body.width)
            path.move(to: CGPoint(x: x - halfBase, y: body.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + halfBase, y: body.minY))
        case .leading:
            let y = along(body.minY, body.height)
            path.move(to: CGPoint(x: body.minX, y: y - halfBase))
            path.addLine(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: body.minX, y: y + halfBase))
        case .trailing:
            let y = along(body.minY, body.height)
            path.move(to: CGPoint(x: body.maxX, y: y - halfBase))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            path.addLine(to: CGPoint(x: body.maxX, y: y + halfBase))
        }
        path.closeSubpath()
        return path
    }
}
