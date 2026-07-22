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
        // Hard ceiling on total DFS calls, independent of the path-count limit above. That limit
        // only bounds the OUTPUT — a long, ambiguous span (phrase/idiom entries can run well past
        // a dozen characters) can have enough branching at each position that the search explores
        // many dead-end branches before ever completing one full path to `endIndex`. Without a
        // separate bound on the exploration itself, that's effectively unbounded work, which hung
        // the main thread long enough to trigger a watchdog crash on a real proverb-length entry.
        var visitedNodes = 0
        let nodeBudget = 4000

        // Depth-first traversal collecting all valid segmentation paths up to the limit.
        func dfs(current: String.Index, path: [String]) {
            guard visitedNodes < nodeBudget else { return }
            visitedNodes += 1
            if current == endIndex {
                allPaths.append(path)
                return
            }
            if allPaths.count >= limit { return }
            let next = (edgesByStart[current] ?? []).sorted { $0.surface < $1.surface }
            for edge in next {
                if allPaths.count >= limit || visitedNodes >= nodeBudget { return }
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

    // Finds a two-part [base-surface, auxiliary-surface] split across `edges` that fully covers
    // the span, where the trailing edge's surface is a known compound-verb auxiliary (続ける,
    // つづける, 始める, …).
    //
    // Used to recover compound-verb structure for display when the top-level segmentation instead
    // collapsed the whole word into one lattice edge via Deinflector's compoundVerbRecoveryForms
    // (e.g. さがしつづける → さがす in one step). That collapse is correct for lookup/validity — the
    // edge still resolves to the real dictionary entry — but it discards the auxiliary. buildLattice
    // keeps every dictionary-matching substring as its own edge regardless of which one wins the
    // longest-match selection, so the natural shorter split (さがし, つづける) is still present among
    // `edges`; this just needs to find it. Returns raw SURFACES, not lemmas — `edge.lemma` is only
    // ever populated by SegmentListView's own display hydration, never by buildLattice itself, so
    // it's empty here; callers should resolve each piece through Segmenter.preferredLemma(for:) to
    // get a real dictionary form (さがし → さがす) before feeding these into DerivationAnalyzer.
    //
    // `lemmaResolver`, when given, also matches an INFLECTED tail edge against `auxiliaries` by its
    // resolved lemma — e.g. 歩いてゆこう's tail edge is the volitional ゆこう, which never literally
    // equals the dictionary-form "ゆく" entry in `auxiliaries` no matter what's in the set, but
    // resolves to it. Optional and defaults to nil (surface-only matching, the original behavior)
    // so existing callers that don't need this compile unchanged.
    static func auxiliaryVerbSplit(
        from edges: [LatticeEdge],
        auxiliaries: Set<String>,
        lemmaResolver: ((String) -> String?)? = nil
    ) -> [String]? {
        guard let start = edges.map(\.start).min(), let end = edges.map(\.end).max() else { return nil }

        // Two passes: auxiliaries attach either after a te/で linker (歩いて+ゆく, 食べて+しまう) or
        // directly to a masu-stem (さがし+つづける, 食べ+始める). `edges` carries no ordering
        // guarantee, so without a first, constrained pass a shorter coincidental tail can win before
        // the linguistically correct one is even considered (歩いてゆこう's "いてゆこう" happens to
        // deinflect to the unrelated real auxiliary いる, beating the correct headEdge "歩いて" +
        // tailEdge "ゆこう" split). Try the te/で-linked reading first — the same gate
        // DerivationAnalyzer's own teAuxiliaries rule uses — then fall back to the unconstrained
        // masu-stem reading so that category keeps working exactly as before.
        for requireTeLinker in [true, false] {
            for tailEdge in edges where tailEdge.end == end {
                let matchesSurface = auxiliaries.contains(tailEdge.surface)
                let matchesLemma = lemmaResolver.flatMap { resolve in resolve(tailEdge.surface) }
                    .map { auxiliaries.contains($0) } ?? false
                guard matchesSurface || matchesLemma else { continue }
                guard let headEdge = edges.first(where: { $0.start == start && $0.end == tailEdge.start }) else { continue }
                if requireTeLinker {
                    guard headEdge.surface.hasSuffix("て") || headEdge.surface.hasSuffix("で") else { continue }
                }
                return [headEdge.surface, tailEdge.surface]
            }
        }
        return nil
    }
}
