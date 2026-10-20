import SwiftUI

// Wrapping flow layout: each subview takes its natural width and wraps to the next row when it
// would overflow the available width — no fixed columns. Used by tag-chip editors (Settings) and
// the subtitle-import vocab picker so chips size to their content. (iOS 16+ Layout protocol;
// deployment target is well above that.)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    // Centers each item on its row's height instead of top-aligning it (mixed-height chips).
    var centersVertically = false

    // Measures the wrapped rows to report the total height for the proposed width.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widestRow = max(widestRow, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, x - spacing)
        let resolvedWidth = proposal.width ?? widestRow
        return CGSize(width: resolvedWidth, height: y + rowHeight)
    }

    // Places each subview left-to-right at its natural size, wrapping to a new row on overflow.
    // Rows are collected first so every item can be centered on its row's height when asked.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x = bounds.minX
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                rows.append([])
                x = bounds.minX
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var itemX = bounds.minX
            for item in row {
                let offset = centersVertically ? (rowHeight - item.size.height) / 2 : 0
                subviews[item.index].place(at: CGPoint(x: itemX, y: y + offset), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                itemX += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
