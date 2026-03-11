import SwiftUI

// Hosts runtime lattice inspection helpers for the read screen.
extension ReadView {
    // Prints the retained lattice section for the current selected segment so decomposition candidates are visible in logs.
    func debugPrintLatticeSectionForCurrentSelection(at selectedLocation: Int) {
        guard let selectedBounds = selectedMergedEdgeBounds ?? initialMergedEdgeBounds(for: selectedLocation) else {
            return
        }

        let selectedStart = segmentationEdges[selectedBounds.lowerBound].start
        let selectedEnd = segmentationEdges[selectedBounds.upperBound].end
        let selectedSurface = String(text[selectedStart..<selectedEnd])
        let selectedRange = NSRange(selectedStart..<selectedEnd, in: text)
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            return
        }

        let sectionEdges = segmentationLatticeEdges
            .filter { edge in
                edge.start >= selectedStart && edge.end <= selectedEnd
            }
            .sorted { lhs, rhs in
                let lhsRange = NSRange(lhs.start..<lhs.end, in: text)
                let rhsRange = NSRange(rhs.start..<rhs.end, in: text)

                if lhsRange.location != rhsRange.location {
                    return lhsRange.location < rhsRange.location
                }

                if lhsRange.length != rhsRange.length {
                    return lhsRange.length > rhsRange.length
                }

                if lhs.surface != rhs.surface {
                    return lhs.surface < rhs.surface
                }

                return lhs.lemma < rhs.lemma
            }

        print("LATTICE SECTION \(selectedRange.location)->\(selectedRange.location + selectedRange.length) \(selectedSurface)")
        if sectionEdges.isEmpty {
            print("  (no retained lattice edges inside selection)")
            return
        }

        for edge in sectionEdges {
            let edgeRange = NSRange(edge.start..<edge.end, in: text)
            guard edgeRange.location != NSNotFound, edgeRange.length > 0 else {
                continue
            }

            print("  \(edgeRange.location)->\(edgeRange.location + edgeRange.length) \(edge.surface) [lemma: \(edge.lemma)]")
        }

        let decompositionPaths = latticeDecompositionPaths(
            within: selectedStart..<selectedEnd,
            maxPathCount: 12
        )

        if decompositionPaths.isEmpty {
            print("  decompositions: none")
            return
        }

        print("  decompositions:")
        for path in decompositionPaths {
            let surfaces = path.map(\.surface).joined(separator: " | ")
            print("    \(surfaces)")
        }
    }

    // Enumerates bounded lattice paths that exactly cover the selected span so component candidates are easy to inspect.
    func latticeDecompositionPaths(within selectedRange: Range<String.Index>, maxPathCount: Int) -> [[LatticeEdge]] {
        var edgesByStart: [String.Index: [LatticeEdge]] = [:]

        for edge in segmentationLatticeEdges {
            if edge.start >= selectedRange.lowerBound && edge.end <= selectedRange.upperBound {
                edgesByStart[edge.start, default: []].append(edge)
            }
        }

        for key in edgesByStart.keys {
            edgesByStart[key]?.sort { lhs, rhs in
                let lhsLength = text.distance(from: lhs.start, to: lhs.end)
                let rhsLength = text.distance(from: rhs.start, to: rhs.end)
                if lhsLength != rhsLength {
                    return lhsLength > rhsLength
                }

                if lhs.surface != rhs.surface {
                    return lhs.surface < rhs.surface
                }

                return lhs.lemma < rhs.lemma
            }
        }

        var results: [[LatticeEdge]] = []
        collectLatticeDecompositionPaths(
            from: selectedRange.lowerBound,
            targetEnd: selectedRange.upperBound,
            edgesByStart: edgesByStart,
            currentPath: [],
            results: &results,
            maxPathCount: maxPathCount
        )

        return results.filter { path in
            path.count > 1
        }
    }

    // Walks the retained lattice recursively to collect exact-cover paths within the selected span.
    func collectLatticeDecompositionPaths(
        from currentIndex: String.Index,
        targetEnd: String.Index,
        edgesByStart: [String.Index: [LatticeEdge]],
        currentPath: [LatticeEdge],
        results: inout [[LatticeEdge]],
        maxPathCount: Int
    ) {
        if results.count >= maxPathCount {
            return
        }

        if currentIndex == targetEnd {
            if currentPath.isEmpty == false {
                results.append(currentPath)
            }
            return
        }

        guard let candidates = edgesByStart[currentIndex], candidates.isEmpty == false else {
            return
        }

        for edge in candidates {
            if results.count >= maxPathCount {
                return
            }

            collectLatticeDecompositionPaths(
                from: edge.end,
                targetEnd: targetEnd,
                edgesByStart: edgesByStart,
                currentPath: currentPath + [edge],
                results: &results,
                maxPathCount: maxPathCount
            )
        }
    }
}