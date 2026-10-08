import Foundation
import Observation

// Owns ReadView's whole-song alignment UI state: the in-flight flag + live progress text behind
// the karaoke bar's spinner, and the failure message behind its alert. One set of fields covers
// both entry points — the subtitle popup's first-time alignment and the bar's own re-align —
// so there is a single progress display (the bar's chip) and a single failure alert. Extracted
// from ReadView's own @State — see LLMCorrectionUIState for the same rationale applied to the
// LLM-correction feature.
@Observable
final class LyricAlignmentUIState {
    var isAligning = false
    var progressMessage = ""
    var errorMessage = ""
}
