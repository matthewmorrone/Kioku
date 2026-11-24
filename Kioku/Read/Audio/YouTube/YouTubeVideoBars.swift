import CoreGraphics
import Foundation

// The black borders baked into a video's own picture (letterbox, pillarbox), as the fraction of the
// frame each edge covers. Used to zoom the player past them.
nonisolated struct YouTubeVideoBars: Equatable, Sendable {
    var top = 0.0
    var bottom = 0.0
    var left = 0.0
    var right = 0.0

    static let none = YouTubeVideoBars()

    // True when there is nothing worth cropping.
    var isNone: Bool { top == 0 && bottom == 0 && left == 0 && right == 0 }

    // The picture inside the bars, as fractions of the frame (origin top-left).
    var content: CGRect {
        CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
    }
}
