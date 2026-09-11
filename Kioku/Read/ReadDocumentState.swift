import Foundation
import Observation

// Owns the note ReadView is currently displaying: its text, which stored note it came from, the
// segmentation derived from it (persisted overrides, lattice, edges, ranges), the per-location
// furigana maps, the recompute tasks that keep those in sync, and the render caches derived from
// them. Extracted from ReadView's own @State — see LLMCorrectionUIState for the same rationale
// applied to the LLM-correction feature.
@Observable
final class ReadDocumentState {
    var text = ""
    var activeNoteID: UUID?
    var isLoadingSelectedNote = false
    // Records the value that loadSelectedNoteIfNeeded just wrote into `text` so the deferred
    // SwiftUI .onChange(of: text) handler can recognize the load-assignment and skip its
    // recompute/persist work. Without this guard every note open triggers a redundant second
    // refreshSegmentationRanges right after the explicit one in the load path.
    var lastLoadedTextSnapshot: String?

    var segments: [SegmentRange]?
    var segmentLatticeEdges: [LatticeEdge] = []
    var segmentEdges: [LatticeEdge] = []
    var segmentRanges: [Range<String.Index>] = []
    var unknownSegmentLocations: Set<Int> = []
    // True once the user has manually changed this note's segmentation (merge/split) or its
    // readings (pin/unpin furigana), or applied an LLM correction. Drives the reset button's
    // enabled state. `segments != nil` can't stand in for this: import precompute persists the
    // *computed* segmentation to disk, so a freshly-loaded, never-edited note still has non-nil
    // segments. This flag is set only at genuine user-mutation funnels and cleared on note load
    // and reset, so it stays false for precomputed-but-unedited notes.
    var hasManualSegmentationEdits = false
    var segmentationRefreshTask: Task<Void, Never>?
    var pendingAutoSegQueue: [PendingAutoSegRequest] = []

    var furiganaBySegmentLocation: [Int: String] = [:]
    var furiganaLengthBySegmentLocation: [Int: Int] = [:]
    // Locations whose wide furigana entries came from the synthesis pass (per-character
    // concatenation, e.g. ものご for 物語 when the dict reading isn't yet loaded). Tracked
    // in-memory so a later recompute with a real dict-derived compound reading can replace
    // them. On note load this set is reconstructed by `performScheduleFuriganaGeneration`'s
    // pre-apply classifier, which marks any wide entry whose value matches a naive per-
    // character dict concat — precise enough to spare LLM pins (whose value diverges from
    // the concat) but aggressive enough to recover disk state poisoned by pre-gate code.
    var synthesizedFuriganaLocations: Set<Int> = []
    var furiganaComputationTask: Task<Void, Never>?

    // Cache for the saved-highlight set so it isn't recomputed (dictionary-lookup sweep) on
    // every body eval.
    var savedHighlightMemo = SavedHighlightMemo()
    // Cache for the "hide furigana for known words" segment set — same memoization rationale
    // as savedHighlightMemo above.
    var knownWordFuriganaMemo = KnownWordFuriganaMemo()
}
