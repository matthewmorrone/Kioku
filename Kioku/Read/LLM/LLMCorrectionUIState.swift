import Foundation
import Observation

// Owns ReadView's state for reviewing a segmentation correction that arrived with a song
// breakdown: pending per-location changes awaiting confirm/reject, and the error/popover alerts
// around them. Extracted from ReadView's own @State so the review reads as one unit.
@Observable
final class LLMCorrectionUIState {
    var isShowingLLMCorrectionError = false
    var llmCorrectionErrorMessage = ""

    var pendingLLMChangedLocations: Set<Int> = []
    // Subset of pendingLLMChangedLocations where only the furigana reading changed (surface unchanged).
    var pendingLLMChangedReadingLocations: Set<Int> = []
    var pendingLLMChangesByLocation: [Int: String] = [:]
    // The full proposed segmentation for the current pending correction. NOT applied to
    // document.segmentEdges — corrections stay invisible in the actual text until confirmed.
    // Confirming one location splices its slice of these edges into the document; confirming
    // all applies the whole array. Empty when there's no pending correction.
    var pendingLLMRebuiltEdges: [LatticeEdge] = []
    // The reading each non-empty entry of pendingLLMRebuiltEdges should get once confirmed —
    // aligned index-for-index with the non-empty-surface subset of pendingLLMRebuiltEdges.
    var pendingLLMWorkingEntries: [LLMSegmentEntry] = []
    var hasPendingLLMChanges = false

    var llmChangePopoverText: String = ""
    var llmChangePopoverLocation: Int? = nil
    var isShowingLLMChangePopover = false
}
