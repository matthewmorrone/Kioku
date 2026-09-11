import Foundation
import Observation
import UIKit

// Owns ReadView's segment-selection state: which segment is selected for lookup, the merged
// bounds/highlight override the lookup sheet operates on, the transient blank-reading flag, a
// tap deferred until dictionary resources load, and the illegal-merge flash. Extracted from
// ReadView's own @State — see LLMCorrectionUIState for the same rationale applied to the
// LLM-correction feature.
@Observable
final class SegmentSelectionUIState {
    var selectedSegmentLocation: Int?
    var selectedHighlightRangeOverride: NSRange?
    var selectedBounds: ClosedRange<Int>?
    var transientBlankReadingSegmentLocation: Int?
    // Holds a tap that arrived before dictionary resources finished loading (readResourcesReady
    // was still false), so it can be replayed automatically once loading completes instead of
    // silently failing — conjugated words need the segmenter's deinflector to resolve a lemma,
    // which isn't ready in the first moment or two after app launch, while plain dictionary-form
    // words happen to work immediately (the raw surface itself is a valid lookup candidate).
    var pendingSegmentTapAfterResourcesReady: (location: Int?, rect: CGRect?, sourceView: UIScrollView?)?
    var illegalMergeBoundaryLocation: Int?
    var illegalMergeFlashTask: Task<Void, Never>?
}
