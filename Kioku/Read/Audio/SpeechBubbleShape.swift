import SwiftUI

// A rounded speech bubble with a small tail on its bottom edge at `tailX` (a 0–1 fraction of the
// width), pointing down at the word it belongs to. Drawn within the frame's bottom `tailHeight`.
nonisolated struct SpeechBubbleShape: Shape {
    var tailX: CGFloat
    var tailHeight: CGFloat = 5
    var cornerRadius: CGFloat = 8

    // Animates the tail sliding along the edge as the bubble moves.
    var animatableData: CGFloat {
        get { tailX }
        set { tailX = newValue }
    }

    // The bubble body above the tail, with the tail cut into its bottom edge.
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)
        var path = Path(roundedRect: body, cornerRadius: min(cornerRadius, body.height / 2))
        let halfBase = min(5, body.width / 4)
        let x = min(max(rect.minX + rect.width * tailX, body.minX + cornerRadius + halfBase), body.maxX - cornerRadius - halfBase)
        path.move(to: CGPoint(x: x - halfBase, y: body.maxY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x + halfBase, y: body.maxY))
        path.closeSubpath()
        return path
    }
}
