import UIKit
import CoreText

// CoreText-based replacement for TextKit 2 in the Read view.
//
// This file is the layout engine: pure value-types + pure computation. Given an attributed
// string and a width, it produces a deterministic list of laid-out lines and exposes per-
// character-range geometry queries. No drawing, no UIView coupling — that lives in
// KiokuCoreTextView.
//
// Coordinate convention: all output Y values are UIKit coordinates (origin top-left, Y grows
// down). CoreText uses bottom-up coordinates internally; the engine flips once at line-build
// time so every consumer sees a single coordinate space.

// One laid-out line. Owns its CTLine plus enough metadata to draw, hit-test, and report rects
// for any sub-range of the source attributed string.
struct KiokuLineLayout {
    let line: CTLine
    // Top-left origin of this line's typographic box in UIKit (Y-down) coordinates, relative
    // to the renderer's content origin.
    let origin: CGPoint
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    let width: CGFloat
    // Range of UTF-16 units in the source attributed string this line covers.
    let stringRange: NSRange

    var height: CGFloat { ascent + descent + leading }
    var baselineY: CGFloat { origin.y + ascent }
    var frame: CGRect { CGRect(x: origin.x, y: origin.y, width: width, height: height) }
}

final class KiokuTextLayoutEngine {

    private(set) var attributedString: NSAttributedString
    private(set) var widthConstraint: CGFloat
    // Inset applied around the laid-out lines. Mirrors UITextView.textContainerInset semantics
    // so callers can keep parity with the existing renderer's positioning math.
    private(set) var contentInset: UIEdgeInsets

    private(set) var lines: [KiokuLineLayout] = []
    // Total content size (line block + content inset). Drives scroll-view contentSize parity.
    private(set) var contentSize: CGSize = .zero

    init(
        attributedString: NSAttributedString = NSAttributedString(),
        widthConstraint: CGFloat = 0,
        contentInset: UIEdgeInsets = .zero
    ) {
        self.attributedString = attributedString
        self.widthConstraint = max(0, widthConstraint)
        self.contentInset = contentInset
        rebuildLayout()
    }

    // Updates the source string. Triggers relayout if the new value differs from the current.
    func setAttributedString(_ newValue: NSAttributedString) {
        guard attributedString.isEqual(to: newValue) == false else { return }
        attributedString = newValue
        rebuildLayout()
    }

    // Updates the wrapping width. Triggers relayout if the new width differs by ≥0.5pt; smaller
    // diffs are ignored to avoid relayout thrash on sub-pixel bounds adjustments.
    func setWidthConstraint(_ newValue: CGFloat) {
        let clamped = max(0, newValue)
        guard abs(clamped - widthConstraint) >= 0.5 else { return }
        widthConstraint = clamped
        rebuildLayout()
    }

    // Updates the content inset. Origins shift but no reshaping is required.
    func setContentInset(_ newValue: UIEdgeInsets) {
        guard newValue != contentInset else { return }
        contentInset = newValue
        rebuildLayout()
    }

    // MARK: - Geometry queries

    // Returns the smallest rectangle covering every glyph in the given UTF-16 range. Matches
    // the semantics of UITextView.firstRect(for:) — when the range spans multiple lines, only
    // the first line's portion is returned. Returns nil for empty ranges or out-of-bounds.
    func firstRect(forCharacterRange range: NSRange) -> CGRect? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard let line = lines.first(where: { NSIntersectionRange($0.stringRange, range).length > 0 }) else {
            return nil
        }
        let intersection = NSIntersectionRange(line.stringRange, range)
        return rect(in: line, forCharacterRange: intersection)
    }

    // Returns the rectangle covering the given character range within the supplied line. The
    // range must be a subset of line.stringRange (caller's responsibility to clip).
    func rect(in line: KiokuLineLayout, forCharacterRange range: NSRange) -> CGRect {
        let startX = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
        let endX = CTLineGetOffsetForStringIndex(line.line, range.location + range.length, nil)
        let leftX = min(startX, endX)
        let rightX = max(startX, endX)
        return CGRect(
            x: line.origin.x + leftX,
            y: line.origin.y,
            width: rightX - leftX,
            height: line.height
        )
    }

    // Maps a point in renderer coordinates to its UTF-16 character index. Returns nil when
    // the point falls outside the laid-out content area.
    func characterIndex(at point: CGPoint) -> Int? {
        // Binary-search the line whose Y range covers the point.
        guard let line = lines.first(where: { point.y >= $0.origin.y && point.y < $0.origin.y + $0.height }) else {
            return nil
        }
        let localPoint = CGPoint(x: point.x - line.origin.x, y: point.y - line.origin.y)
        let index = CTLineGetStringIndexForPosition(line.line, localPoint)
        guard index != kCFNotFound else { return nil }
        return index
    }

    // MARK: - Layout

    private func rebuildLayout() {
        lines.removeAll(keepingCapacity: true)

        let availableWidth = max(0, widthConstraint - contentInset.left - contentInset.right)
        guard attributedString.length > 0, availableWidth > 0 else {
            contentSize = CGSize(
                width: contentInset.left + contentInset.right,
                height: contentInset.top + contentInset.bottom
            )
            return
        }

        let typesetter = CTTypesetterCreateWithAttributedString(attributedString)
        let totalLength = attributedString.length
        var startIndex = 0
        var penY: CGFloat = contentInset.top

        while startIndex < totalLength {
            let lineLength = CTTypesetterSuggestLineBreak(typesetter, startIndex, Double(availableWidth))
            guard lineLength > 0 else { break }

            let stringRange = NSRange(location: startIndex, length: lineLength)
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(startIndex, lineLength))

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            let layout = KiokuLineLayout(
                line: line,
                origin: CGPoint(x: contentInset.left, y: penY),
                ascent: ascent,
                descent: descent,
                leading: leading,
                width: lineWidth,
                stringRange: stringRange
            )
            lines.append(layout)

            penY += layout.height
            startIndex += lineLength
        }

        let lineBlockWidth = lines.map(\.width).max() ?? 0
        contentSize = CGSize(
            width: lineBlockWidth + contentInset.left + contentInset.right,
            height: penY + contentInset.bottom
        )
    }
}
