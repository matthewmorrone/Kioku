import Foundation
import Observation
import CoreGraphics

// Owns ReadView's edit-mode transition and scroll-position state: whether the read/edit toggle
// is active, the sheet-swipe transition flag, and the scroll offset shared between the read and
// edit surfaces (snapshotted into the memo when edit mode is entered). Extracted from ReadView's
// own @State — see LLMCorrectionUIState for the same rationale applied to the LLM-correction
// feature.
@Observable
final class EditModeScrollUIState {
    var isEditMode = false
    var isSheetSwipeTransitionActive = false
    var sharedScrollOffsetY: CGFloat = 0
    // Live mirror of the CT read view's scroll offset; snapshotted into sharedScrollOffsetY
    // when edit mode is entered. See ReadScrollOffsetMemo for why it's not @State itself.
    var readScrollOffsetMemo = ReadScrollOffsetMemo()
    // Extra contentInset.bottom currently injected into the read scroll view so the lookup
    // sheet can keep the selected segment visible even when it sits past the natural bottom
    // of the note. Tracked here so dismissal removes exactly what was added, regardless of
    // any other inset changes the scroll view's owner might have made in the meantime.
    var appliedSheetBottomInset: CGFloat = 0
}
