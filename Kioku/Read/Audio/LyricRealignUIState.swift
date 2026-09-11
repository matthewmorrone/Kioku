import Foundation
import Observation

// Owns ReadView's whole-song Re-align UI state: the in-flight flag + live progress text behind
// the karaoke bar's spinner, and the failure message behind its alert. Extracted from
// ReadView's own @State — see LLMCorrectionUIState for the same rationale applied to the
// LLM-correction feature.
@Observable
final class LyricRealignUIState {
    var isReAligningWholeNote = false
    var reAlignProgressMessage = ""
    var cueRealignErrorMessage = ""
}
