import Foundation
import Observation

// Owns ReadView's LLM-correction UI state: in-flight request tracking, pending
// per-location changes awaiting confirm/reject, and the error/popover/rerun-confirm
// alerts around it. Extracted from ReadView's own @State so the correction feature
// reads as one unit instead of 15 loose properties in a 90-property view.
@Observable
final class LLMCorrectionUIState {
    var isRequestingLLMCorrection = false
    var isShowingLLMCorrectionError = false
    var llmCorrectionErrorMessage = ""
    // Populated only when the failure was LLMCorrectionError.unparseableAfterSalvage — the raw
    // response that couldn't be parsed (even after on-device salvage) plus the reason, so the
    // alert's "Retry with Feedback" action can resend the original provider a corrected request
    // instead of a blind identical retry. Nil for every other failure kind (network, no key,
    // etc.), which the alert uses to decide whether to show that extra button at all.
    var llmCorrectionRetryContext: (rawResponse: String, reason: String)?
    var llmCorrectionTask: Task<Void, Never>?

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
    var isShowingLLMRerunConfirm = false
    // Sparkles tapped on a fresh note: explains what the correction does before it runs.
    var isShowingLLMStartConfirm = false
    // Sparkles tapped mid-run: confirms before discarding the correction in progress.
    var isShowingLLMCancelConfirm = false

    // True once an LLM correction has actually produced changes (pending or already confirmed)
    // for the currently-loaded note. Gates the "Re-run AI Correction?" confirm so it only warns
    // about replacing prior corrections — not on the first run. A merely-pending, unconfirmed
    // correction doesn't route through that warning anyway: tapping sparkles while
    // hasPendingLLMChanges is true confirms the pending proposal instead of starting a new run.
    // Reset when a note loads or corrections are cleared. (Session-scoped: reloading a
    // previously-corrected note starts fresh, so the first tap after reload runs without the
    // warning.)
    var hasAppliedLLMCorrectionForCurrentNote = false
}
