import Foundation
import Observation

// Owns ReadView's whole-note lyric re-align UI state: the top-of-card "Re-align" run
// (progress + error) and the subtitle editor sheet + mismatch-count dialog it can surface.
// Extracted from ReadView's own @State — see LLMCorrectionUIState for the same rationale
// applied to the LLM-correction feature.
@Observable
final class LyricRealignUIState {
    // Cue index currently being re-aligned by the lyric view's in-place "fix word sweep"
    // control; nil when idle. Drives the per-cue spinner in the lyric editing row and
    // gates concurrent re-align requests to one at a time.
    var realigningCueIndex: Int? = nil
    // Surfaced in a dedicated alert when an in-place cue re-alignment fails, so the
    // failure doesn't ride in under the unrelated "Generate SRT Failed" title.
    var cueRealignErrorMessage = ""
    // Drives the lyric view's top "Re-align" action: a full from-scratch re-run of the CTC
    // pipeline over the attached audio (vs. the per-cue "fix word sweep"). The bar shows a
    // spinner + progress while this is true; the message carries the live percent.
    var isReAligningWholeNote = false
    var reAlignProgressMessage = ""

    var isShowingSubtitleEditor = false
    var isShowingSubtitleMismatchDialog = false
    var subtitleMismatchCount = 0
}
