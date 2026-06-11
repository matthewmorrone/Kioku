import SwiftUI

// Wrapping flow layout: each subview takes its natural width and wraps to the next row when it would
// overflow the available width — no fixed columns. Used by tag-chip editors (Settings) and the
// subtitle-import vocab picker so chips size to their content. (iOS 16+ Layout protocol; deployment
// target is well above that.) Hoisted from SettingsView's private copy when SubtitleImportView
// needed the same layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
