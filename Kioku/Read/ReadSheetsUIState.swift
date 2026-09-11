import Foundation
import Observation

// Owns the presentation flags for ReadView's toolbar-launched sheets and popovers. Extracted
// from ReadView's own @State — see LLMCorrectionUIState for the same rationale applied to the
// LLM-correction feature.
@Observable
final class ReadSheetsUIState {
    var isShowingSegmentList = false
    var isShowingDisplayOptions = false
    // Drives the Saved Highlight category submenu as its own popover rather than a SwiftUI
    // `Menu` — a Menu auto-dismisses after every tap (including a Toggle tap), which defeats
    // flipping more than one category per visit. A popover of real Toggle rows doesn't.
    var isShowingSavedHighlightCategories = false
    var isShowingBreakdownSheet = false
}
