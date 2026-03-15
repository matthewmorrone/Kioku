import Foundation
import Combine

// Encapsulates runtime lattice graph construction and lightweight neighborhood queries.
final class Lattice {
    private(set) var text: String = ""
    private(set) var nodesByID: [Int: (surface: String, lemma: String, startOffset: Int, endOffset: Int)] = [:]
    private(set) var adjacencyByNodeID: [Int: Set<Int>] = [:]
    private static let auxiliaryLemmaRules = loadAuxiliaryLemmaRules()

    // Rebuilds node and adjacency maps from a retained lattice edge list so callers can query subsets quickly.
    func rebuild(text: String, edges: [LatticeEdge]) {
        self.text = text

        let sortedEdges = Self.sortedEdges(edges, in: text)

        var builtNodes: [Int: (surface: String, lemma: String, startOffset: Int, endOffset: Int)] = [:]
        for (index, edge) in sortedEdges.enumerated() {
            let range = NSRange(edge.start..<edge.end, in: text)
            builtNodes[index] = (
                surface: edge.surface,
                lemma: edge.lemma,
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

    // Returns a lightweight morphological component list for one node using a caller-provided inflection-chain source.
    func nodeComponents(
        nodeId: Int,
        inflectionChain: (_ surface: String, _ lemma: String) -> [String]
    ) -> [(lemma: String, role: String)] {
        guard let node = nodesByID[nodeId] else {
            return []
        }

        let chain = inflectionChain(node.surface, node.lemma)
        guard chain.isEmpty == false else {
            return [(lemma: node.lemma, role: "base")]
        }

        var components: [(lemma: String, role: String)] = [(lemma: node.lemma, role: "verb stem")]
        for chainItem in chain {
            components.append((lemma: auxiliaryLemma(for: chainItem), role: chainItem))
        }

        return components
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
        resolutionSummary: (_ surface: String, _ lemma: String) -> String
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

            let summary = resolutionSummary(edge.surface, edge.lemma)
            lines.append(
                "  \(edgeRange.location)->\(edgeRange.location + edgeRange.length) \(edge.surface) [lemma: \(edge.lemma)] [\(summary)]"
            )
        }

        return lines
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

            if lhs.surface != rhs.surface {
                return lhs.surface < rhs.surface
            }

            return lhs.lemma < rhs.lemma
        }
    }

    // Maps one chain label to a canonical auxiliary lemma hint for node-component presentation.
    private func auxiliaryLemma(for chainLabel: String) -> String {
        let lowercaseLabel = chainLabel.lowercased()

        for rule in Self.auxiliaryLemmaRules where lowercaseLabel.contains(rule.keyword) {
            return rule.lemma
        }

        return chainLabel
    }

    // Loads ordered keyword-to-auxiliary mappings from bundled JSON for data-driven component expansion.
    private static func loadAuxiliaryLemmaRules(
        bundle: Bundle = .main,
        resourceName: String = "lattice_auxiliary_lemmas",
        fileExtension: String = "json"
    ) -> [(keyword: String, lemma: String)] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: fileExtension) else {
            print("Missing lattice auxiliary lemma file: \(resourceName).\(fileExtension)")
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let pairs = try JSONDecoder().decode([[String]].self, from: data)
            return pairs.compactMap { pair in
                guard pair.count == 2 else {
                    return nil
                }

                return (keyword: pair[0].lowercased(), lemma: pair[1])
            }
        } catch {
            print("Failed to decode lattice auxiliary lemma file: \(error)")
            return []
        }
    }
}
