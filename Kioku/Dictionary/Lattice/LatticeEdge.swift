import Foundation
import Combine

// Represents one directed edge in a segmentation lattice over source text.
struct LatticeEdge {
    let start: String.Index
    let end: String.Index
    let surface: String
    // Best resolved lemma for this surface (empty string when no POS metadata is loaded).
    var lemma: String = ""
    // Entry IDs from the trie's EntryIDPool for this surface/lemma combination.
    var indices: [Int] = []
    // Bitfield of PartOfSpeech flags for this edge; 0 when trie was built without metadata.
    var partOfSpeech: UInt64 = 0
    // True when the surface resolves through the dictionary trie (including deinflection).
    var isDictionaryMatch: Bool = false
    // Unified frequency score (~0–7 Zipf-equivalent; higher = more common) for this surface/lemma,
    // derived from jpdb_rank (and wordfreq Zipf when present) at lattice-build time. 0 means no
    // frequency data — treated as rare. This is the core statistical input to the global cost model.
    var frequencyScore: Double = 0
    // True when the surface ends in a known grammatical kana (た/だ/て/で/よ) and the surface
    // minus that last char is itself a dict entry — i.e., the entry decomposes into a
    // prefix + grammatical ending. Used by the Viterbi node-cost to discourage rare bundled
    // entries (たいよ, 生まれた) from outranking the compositional split.
    var decomposesAtGrammaticalEnding: Bool = false
    // IPADic context IDs tagged at dictionary-build time. When both are populated on adjacent
    // edges, Viterbi looks up the connection cost directly in IPADic's matrix.bin instead of
    // bucketing through POS classes — the same scoring fidelity MeCab itself uses. nil when
    // the surface lacked tags (deinflected forms, fallback edges, untagged trie inserts).
    var ipadicLeftID: Int32? = nil
    var ipadicRightID: Int32? = nil
    // Accumulated Viterbi score for the best path ending at this edge; nil until Viterbi runs.
    var viterbiScore: Int? = nil
    // Character offset of the predecessor edge's start in the best Viterbi path; nil until Viterbi runs.
    var viterbiPrevStart: Int? = nil

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
