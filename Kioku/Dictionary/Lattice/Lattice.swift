import Foundation
import Combine

// Encapsulates runtime lattice graph construction and lightweight neighborhood queries.
final class Lattice {
    private(set) var text: String = ""
    private(set) var nodesByID: [Int: (surface: String, startOffset: Int, endOffset: Int)] = [:]
    private(set) var adjacencyByNodeID: [Int: Set<Int>] = [:]
    // Rebuilds node and adjacency maps from a retained lattice edge list so callers can query subsets quickly.
    func rebuild(text: String, edges: [LatticeEdge]) {
        self.text = text

        let sortedEdges = Self.sortedEdges(edges, in: text)

        var builtNodes: [Int: (surface: String, startOffset: Int, endOffset: Int)] = [:]
        for (index, edge) in sortedEdges.enumerated() {
            let range = NSRange(edge.start..<edge.end, in: text)
            builtNodes[index] = (
                surface: edge.surface,
                startOffset: range.location,
                endOffset: range.location + range.length
            )
        }

        var adjacency: [Int: Set<Int>] = [:]
        let nodeIDs = builtNodes.keys.sorted()

        for lhsNodeID in nodeIDs {
            guard let lhsNode = builtNodes[lhsNodeID] else {
                continue
            }

            for rhsNodeID in nodeIDs where rhsNodeID != lhsNodeID {
                guard let rhsNode = builtNodes[rhsNodeID] else {
                    continue
                }

                let isAdjacent = lhsNode.endOffset == rhsNode.startOffset || rhsNode.endOffset == lhsNode.startOffset
                if isAdjacent {
                    adjacency[lhsNodeID, default: []].insert(rhsNodeID)
                }
            }
        }

        nodesByID = builtNodes
        adjacencyByNodeID = adjacency

        // Log the full lattice once per rebuild so the segmentation result is inspectable in the console.
        let lines = nodeIDs.map { id -> String in
            guard let node = builtNodes[id] else { return "\(id): <missing>" }
            let neighbours = (adjacency[id] ?? []).sorted().map(String.init).joined(separator: ",")
            return "  [\(id)] \(node.startOffset)..\(node.endOffset) \"\(node.surface)\"  adj:[\(neighbours)]"
        }
        print("[Lattice] rebuilt \(builtNodes.count) nodes for \"\(text)\"\n" + lines.joined(separator: "\n"))
    }

    // Returns lattice node IDs reachable within one undirected edge distance threshold from a seed node.
    func neighbors(nodeId: Int, distance: Int) -> [Int] {
        guard distance > 0 else {
            return []
        }

        guard nodesByID[nodeId] != nil else {
            return []
        }

        var visited = Set<Int>([nodeId])
        var frontier: [Int] = [nodeId]

        for _ in 0..<distance {
            var nextFrontier: [Int] = []
            for frontierNodeID in frontier {
                let neighbors = adjacencyByNodeID[frontierNodeID] ?? []
                for neighborID in neighbors where visited.contains(neighborID) == false {
                    visited.insert(neighborID)
                    nextFrontier.append(neighborID)
                }
            }

            frontier = nextFrontier
            if frontier.isEmpty {
                break
            }
        }

        visited.remove(nodeId)
        return visited.sorted()
    }

    // Extracts and deterministically sorts edges that are fully enclosed by a selected source-text span.
    static func sectionEdges(
        from edges: [LatticeEdge],
        in text: String,
        selectedStart: String.Index,
        selectedEnd: String.Index
    ) -> [LatticeEdge] {
        guard selectedStart < selectedEnd else {
            return []
        }

        return sortedEdges(
            edges.filter { edge in
                edge.start >= selectedStart && edge.end <= selectedEnd
            },
            in: text
        )
    }

    // Builds deterministic debug output lines for one selected lattice section so UI layers can print without formatting logic.
    static func debugSectionLines(
        sectionEdges: [LatticeEdge],
        in text: String,
        sectionRange: NSRange,
        sectionSurface: String,
        resolutionSummary: (_ surface: String) -> String
    ) -> [String] {
        guard sectionRange.location != NSNotFound, sectionRange.length > 0 else {
            return []
        }

        var lines: [String] = [
            "LATTICE SECTION \(sectionRange.location)->\(sectionRange.location + sectionRange.length) \(sectionSurface)"
        ]

        if sectionEdges.isEmpty {
            lines.append("  (no retained lattice edges inside selection)")
            return lines
        }

        for edge in sectionEdges {
            let edgeRange = NSRange(edge.start..<edge.end, in: text)
            guard edgeRange.location != NSNotFound, edgeRange.length > 0 else {
                continue
            }

            let summary = resolutionSummary(edge.surface)
            lines.append(
                "  \(edgeRange.location)->\(edgeRange.location + edgeRange.length) \(edge.surface) [\(summary)]"
            )
        }

        return lines
    }

    // Returns the subset of already-built node and adjacency maps whose offsets fall within the given NSRange,
    // with no recomputation — purely filters the existing nodesByID and adjacencyByNodeID.
    func slice(range: NSRange) -> (
        nodesByID: [Int: (surface: String, startOffset: Int, endOffset: Int)],
        adjacencyByNodeID: [Int: Set<Int>]
    ) {
        let rangeEnd = range.location + range.length
        let slicedNodes = nodesByID.filter { _, node in
            node.startOffset >= range.location && node.endOffset <= rangeEnd
        }
        let slicedNodeIDs = Set(slicedNodes.keys)
        let slicedAdjacency = adjacencyByNodeID
            .filter { slicedNodeIDs.contains($0.key) }
            .mapValues { $0.intersection(slicedNodeIDs) }
        return (nodesByID: slicedNodes, adjacencyByNodeID: slicedAdjacency)
    }

    // Sorts lattice edges for stable UI presentation and deterministic neighborhood construction.
    private static func sortedEdges(_ edges: [LatticeEdge], in text: String) -> [LatticeEdge] {
        edges.sorted { lhs, rhs in
            let lhsRange = NSRange(lhs.start..<lhs.end, in: text)
            let rhsRange = NSRange(rhs.start..<rhs.end, in: text)

            if lhsRange.location != rhsRange.location {
                return lhsRange.location < rhsRange.location
            }

            if lhsRange.length != rhsRange.length {
                return lhsRange.length > rhsRange.length
            }

            return lhs.surface < rhs.surface
        }
    }

}
