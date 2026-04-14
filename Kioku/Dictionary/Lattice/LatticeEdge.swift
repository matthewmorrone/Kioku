import Foundation
import Combine

// Represents one directed edge in a segmentation lattice over source text.
struct LatticeEdge {
    let start: String.Index
    let end: String.Index
    let surface: String

    // Enumerates all complete paths through the edge DAG, capped to avoid combinatorial explosion.
    // Paths containing single-kana segments not in the ParticleSettings allowlist are excluded.
    static func validPaths(from edges: [LatticeEdge]) -> [[String]] {
        guard edges.isEmpty == false else { return [] }
        guard let startIndex = edges.map({ $0.start }).min(),
              let endIndex = edges.map({ $0.end }).max() else { return [] }

        var edgesByStart: [String.Index: [LatticeEdge]] = [:]
        for edge in edges {
            edgesByStart[edge.start, default: []].append(edge)
        }

        let allowedKana = ParticleSettings.allowed()
        var allPaths: [[String]] = []
        let limit = 24

        // Depth-first traversal collecting all valid segmentation paths up to the limit.
        func dfs(current: String.Index, path: [String]) {
            if current == endIndex {
                allPaths.append(path)
                return
            }
            if allPaths.count >= limit { return }
            let next = (edgesByStart[current] ?? []).sorted { $0.surface < $1.surface }
            for edge in next {
                if allPaths.count >= limit { return }
                // Reject edges that are single-kana bound morphemes not in the allowlist.
                if edge.surface.count == 1,
                   ScriptClassifier.isPureKana(edge.surface),
                   allowedKana.contains(edge.surface) == false {
                    continue
                }
                dfs(current: edge.end, path: path + [edge.surface])
            }
        }

        dfs(current: startIndex, path: [])
        return allPaths
    }
}
