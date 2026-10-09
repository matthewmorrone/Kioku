import SwiftUI

// Split-offset and split-preview helpers for SegmentListView. The body's context
// menu uses `splitPreview` to render proposed cuts, while `rebuildSplitMenuCaches`
// keeps the per-row offset lists pre-sorted so row rendering stays cheap.
extension SegmentListView {
    // Identifies indices that are both a lattice start and end so split options can prefer graph-supported boundaries.
    func latticeBoundaryIndices() -> Set<String.Index> {
        var latticeStarts = Set<String.Index>()
        var latticeEnds = Set<String.Index>()

        for latticeEdge in latticeEdges {
            latticeStarts.insert(latticeEdge.start)
            latticeEnds.insert(latticeEdge.end)
        }

        return latticeStarts.intersection(latticeEnds)
    }

    // Builds valid UTF-16 split offsets for a segment, and the subset of them that land on a
    // lattice-supported boundary, in one walk of the segment's character boundaries (this used to
    // be two separate walks over the same span — rebuildSplitMenuCaches is the only caller and
    // always needs both).
    func splitOffsetsAndLatticeBacked(for edge: LatticeEdge, boundaryIndices: Set<String.Index>) -> (all: [Int], latticeBacked: Set<Int>) {
        guard edge.start < edge.end else {
            return ([], [])
        }

        var offsets: [Int] = []
        var latticeBackedOffsets = Set<Int>()
        var cursor = edge.start
        var utf16Offset = 0

        while cursor < edge.end {
            let nextIndex = text.index(after: cursor)
            utf16Offset += text[cursor..<nextIndex].utf16.count
            if nextIndex < edge.end {
                offsets.append(utf16Offset)
                if boundaryIndices.contains(nextIndex) {
                    latticeBackedOffsets.insert(utf16Offset)
                }
            }
            cursor = nextIndex
        }

        return (offsets, latticeBackedOffsets)
    }

    // Rebuilds split-menu caches to keep row rendering light even for large segment lists.
    func rebuildSplitMenuCaches() {
        let boundaryIndices = latticeBoundaryIndices()
        var orderedOffsetsByIndex: [Int: [Int]] = [:]
        var latticeBackedOffsetsByIndex: [Int: Set<Int>] = [:]

        orderedOffsetsByIndex.reserveCapacity(edges.count)
        latticeBackedOffsetsByIndex.reserveCapacity(edges.count)

        for (sourceIndex, edge) in edges.enumerated() {
            let (availableOffsets, latticeBackedOffsets) = splitOffsetsAndLatticeBacked(for: edge, boundaryIndices: boundaryIndices)
            let orderedOffsets = availableOffsets.sorted { lhs, rhs in
                let lhsIsLatticeBacked = latticeBackedOffsets.contains(lhs)
                let rhsIsLatticeBacked = latticeBackedOffsets.contains(rhs)
                if lhsIsLatticeBacked != rhsIsLatticeBacked {
                    return lhsIsLatticeBacked
                }

                return lhs < rhs
            }

            orderedOffsetsByIndex[sourceIndex] = orderedOffsets
            latticeBackedOffsetsByIndex[sourceIndex] = latticeBackedOffsets
        }

        orderedSplitOffsetsBySourceIndex = orderedOffsetsByIndex
        latticeBackedSplitOffsetsBySourceIndex = latticeBackedOffsetsByIndex
    }

    // Generates preview text for a proposed split boundary.
    func splitPreview(for surface: String, offsetUTF16: Int) -> (left: String, right: String)? {
        let totalLength = surface.utf16.count
        guard offsetUTF16 > 0, offsetUTF16 < totalLength else {
            return nil
        }

        let splitIndex = String.Index(utf16Offset: offsetUTF16, in: surface)
        let left = String(surface[..<splitIndex])
        let right = String(surface[splitIndex...])
        guard left.isEmpty == false, right.isEmpty == false else {
            return nil
        }

        return (left: left, right: right)
    }
}
