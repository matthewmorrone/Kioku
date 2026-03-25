import SwiftUI

// A flow layout that places subviews left-to-right and wraps to new lines.
// Used by ClozeStudyView to render mixed text + dropdown controls inline,
// preserving baseline alignment within each line.
@available(iOS 16.0, *)
struct InlineWrapLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    // Represents one subview placed on a line, tracking its size and baseline for alignment.
    private struct LineItem {
        let subviewIndex: Int
        let size: CGSize
        let firstBaseline: CGFloat
    }

    // A horizontal run of subviews sharing a baseline-aligned row.
    private struct Line {
        var items: [LineItem] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { ascent + descent }
    }

    // Returns the first-text-baseline offset for a subview, falling back to the bottom edge.
    private func firstBaseline(for subview: LayoutSubview, size: CGSize) -> CGFloat {
        let baseline = subview.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
        if baseline.isFinite, baseline > 0, baseline <= size.height { return baseline }
        return size.height
    }

    // Greedily fills lines left-to-right, starting a new line when the next item would overflow.
    private func computeLines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        lines.reserveCapacity(8)
        var current = Line()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let baseline = firstBaseline(for: subview, size: size)
            let itemWidth = (current.items.isEmpty ? 0 : spacing) + size.width

            if current.items.isEmpty == false, current.width + itemWidth > maxWidth {
                lines.append(current)
                current = Line()
            }

            if current.items.isEmpty == false { current.width += spacing }
            current.items.append(LineItem(subviewIndex: index, size: size, firstBaseline: baseline))
            current.width += size.width
            current.ascent = max(current.ascent, baseline)
            current.descent = max(current.descent, size.height - baseline)
        }

        if current.items.isEmpty == false { lines.append(current) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        let lines = computeLines(maxWidth: maxWidth, subviews: subviews)
        let usedWidth = lines.map(\.width).max() ?? 0
        let totalHeight = lines.enumerated().reduce(CGFloat(0)) { acc, element in
            acc + element.element.height + (element.offset == 0 ? 0 : lineSpacing)
        }
        return CGSize(width: min(usedWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = computeLines(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (lineIndex, line) in lines.enumerated() {
            var x = bounds.minX
            for item in line.items {
                subviews[item.subviewIndex].place(
                    at: CGPoint(x: x, y: y + (line.ascent - item.firstBaseline)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width
                if item.subviewIndex != line.items.last?.subviewIndex { x += spacing }
            }
            y += line.height
            if lineIndex != lines.count - 1 { y += lineSpacing }
        }
    }
}
