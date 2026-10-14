import Foundation
import Observation

// Owns the presentation flags for ReadView's toolbar-launched sheets and popovers.
// Extracted from ReadView's own @State so it reads as one unit.
@Observable
final class ReadSheetsUIState {
    var isShowingSegmentList = false
    var isShowingDisplayOptions = false
    // Drives the Saved Highlight category submenu as its own popover rather than a SwiftUI
    // `Menu` — a Menu auto-dismisses after every tap (including a Toggle tap), which defeats
    // flipping more than one category per visit. A popover of real Toggle rows doesn't.
    var isShowingSavedHighlightCategories = false
    var isShowingBreakdownSheet = false
    // Note-text UTF-16 location the breakdown sheet scrolls to on open (the line holding it), set
    // when it's opened from a lyric cue or a word's source note; nil opens it where it was.
    var breakdownFocusLocation: Int?
    // Whether the breakdown sheet starts playing from the top as it opens (a random breakdown).
    var breakdownAutoplay = false
    // Long-press on the segment-list button: the note's changes from default segmentation and
    // readings (SegmentationChangeList), shown in an alert.
    var isShowingChangesFromDefault = false
    var changesFromDefault: [String] = []
    // English → katakana review sheet (display-options popover): the proposals and the note text
    // they were computed against, so a stale proposal is never spliced into edited text.
    var isShowingTextConversion = false
    var textConversionProposals: [TextConversion] = []
    var textConversionSourceText = ""
    // Learn Spelling form, opened from the lookup sheet for the word that has no entry.
    var isShowingLearnSpelling = false
    var learnSpellingSurface = ""
}
