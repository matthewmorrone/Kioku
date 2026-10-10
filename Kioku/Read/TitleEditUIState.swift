import Foundation
import Observation

// Owns ReadView's note-title editing state: the user override, the OCR/transcription-derived
// fallback shown until one is set, and the rename alert's draft text.
// Extracted from ReadView's own @State so it reads as one unit.
@Observable
final class TitleEditUIState {
    var customTitle = ""
    var fallbackTitle = ""
    var titleDraft = ""
    var isShowingTitleAlert = false
}
