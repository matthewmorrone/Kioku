import Foundation

// A curated, hand-maintained category of surfaces that segmentation should *deprioritize*.
//
// Some short surfaces exist in IPADic as standalone entries (のか, のす, …) and, on raw
// node-cost arithmetic (or raw length, in greedy), outrank the compositional parse they should
// lose to — e.g. のか beating の + か. Rather than scatter `if surface == "のか"` comparisons
// through the scoring algorithm, the *strings* live here as data and the algorithm only asks
// `contains(_:)`. That keeps SegmenterScoring / compareEdgePriority free of literal surfaces.
//
// The demotion is intentionally *soft*. It is consulted in two places, one per engine:
//   • Viterbi — SegmenterScoring.edgeCost adds viterbiDemotedSurfacePenalty to the node cost.
//     A demoted surface can still win if no cheaper global path exists.
//   • Greedy  — Segmenter.compareEdgePriority sinks a demoted candidate below every
//     non-demoted candidate that starts at the same position. A demoted surface is still
//     chosen when it is the only candidate at that position.
//
// This is a denylist of *specific* breakers, not a part-of-speech rule — POS-level handling
// belongs in SegmenterScoring.transitionCost. Add a surface here only when it reliably breaks
// real segmentation and a broader POS rule would risk demoting legitimate words.
nonisolated enum SegmentationDemotions {
    // Hand-maintained. Match is on the raw detected *surface*, not the lemma.
    static let surfaces: Set<String> = [
        "のか",   // particle cluster の + か; spurious as a single token
        "のす",   // spurious; should not absorb の
        "のこ",   // spurious; should not absorb の
        "はも",   // spurious; should not fuse は + も
        "があ",   // spurious; should not fuse が + あ
        "のま",
        "なの",
        "がす",
        "には",
        "にも",
        "よね",
        "か弱い",
        "ような",
        "中二",
        "はと",

        "もし",  // rare 燃す past; almost always も + した (stem + emphatic も + した)
        "もした",  // rare 燃す past; almost always も + した (stem + emphatic も + した)
        "その物",  // spurious fusion; should be その + 物
    ]

    // O(1) membership test used by both segmentation engines.
    static func contains(_ surface: String) -> Bool {
        surfaces.contains(surface)
    }
}
