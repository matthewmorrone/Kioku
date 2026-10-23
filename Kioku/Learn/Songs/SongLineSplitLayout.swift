import SwiftUI

// The expanded breakdown card's split line: rows stacked top to bottom, each row's segments side by
// side at its left, and its glosses in one column to the right of the widest row's segments, so every
// gloss starts at the same x. Children say where they go with SongLineSplitSlotKey. Segments are
// placed at their own size (they're framed to their footprint); glosses take the remaining width;
// a row's background band spans the full width and height of its row.
struct SongLineSplitLayout: Layout {
    var glossSpacing: CGFloat = 8

    // The whole split's size for the proposed width: the rows' heights stacked.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = measuredRows(proposalWidth: proposal.width, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height })
    }

    // Places each row's segments left to right from the left edge and its glosses at the gloss column.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = measuredRows(proposalWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            for index in row.backgrounds {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: row.height)
                )
            }
            var x = bounds.minX
            for (index, size) in row.segments {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width
            }
            for (index, size) in row.glosses {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + row.glossX, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: nil)
                )
            }
            y += row.height
        }
    }

    // Each row's children with their sizes (backgrounds take the row's), the shared gloss column's x,
    // and the row's width and height.
    private func measuredRows(
        proposalWidth: CGFloat?,
        subviews: Subviews
    ) -> [(segments: [(Int, CGSize)], glosses: [(Int, CGSize)], backgrounds: [Int], glossX: CGFloat, width: CGFloat, height: CGFloat)] {
        var segmentsByRow: [Int: [(Int, CGSize)]] = [:]
        var glossesByRow: [Int: [Int]] = [:]
        var backgroundsByRow: [Int: [Int]] = [:]
        for index in subviews.indices {
            let slot = subviews[index][SongLineSplitSlotKey.self]
            switch slot.role {
            case .segment:
                segmentsByRow[slot.row, default: []].append((index, subviews[index].sizeThatFits(.unspecified)))
            case .gloss:
                glossesByRow[slot.row, default: []].append(index)
            case .background:
                backgroundsByRow[slot.row, default: []].append(index)
            }
        }
        // A row is there for its segments or glosses; a background alone doesn't make one.
        let rowIndices = Set(segmentsByRow.keys).union(glossesByRow.keys).sorted()
        let column = rowIndices.map { row in (segmentsByRow[row] ?? []).reduce(0) { $0 + $1.1.width } }.max() ?? 0
        let glossX = column + glossSpacing
        let glossWidth = max(0, (proposalWidth ?? glossX) - glossX)
        return rowIndices.map { row in
            let segments = segmentsByRow[row] ?? []
            let glosses = (glossesByRow[row] ?? []).map { index in
                (index, subviews[index].sizeThatFits(ProposedViewSize(width: glossWidth, height: nil)))
            }
            let segmentWidth = segments.reduce(0) { $0 + $1.1.width }
            let height = max(segments.map(\.1.height).max() ?? 0, glosses.map(\.1.height).max() ?? 0)
            return (segments, glosses.map { ($0.0, CGSize(width: glossWidth, height: $0.1.height)) },
                    backgroundsByRow[row] ?? [], glossX, glosses.isEmpty ? segmentWidth : glossX + glossWidth, height)
        }
    }
}
