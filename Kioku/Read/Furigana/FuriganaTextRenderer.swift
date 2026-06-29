import SwiftUI
import UIKit

// Renders the read-mode text surface with furigana overlayed above segments while preserving text-view layout.
struct FuriganaTextRenderer: UIViewRepresentable {
    let isActive: Bool
    let isOverlayFrozen: Bool
    let text: String
    let isLineWrappingEnabled: Bool
    let segmentationRanges: [Range<String.Index>]
    let selectedSegmentLocation: Int?
    let blankSelectedSegmentLocation: Int?
    let selectedHighlightRangeOverride: NSRange?
    // Optional range whose TEXT is tinted blue (no background band). ExampleSentenceView
    // uses this to mark the target word in example sentences, matching the plain-text
    // fallback's accent-colored run.
    var accentTextRange: NSRange? = nil
    let playbackHighlightRangeOverride: NSRange?
    let activePlaybackCueIndex: Int?
    let illegalMergeBoundaryLocation: Int?
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isVisualEnhancementsEnabled: Bool
    // User-controlled gate for all ruby-spacing adjustments — pre-layout envelope padding,
    // post-layout kern, and line-start exclusions. Kept independent of visual enhancements so
    // toggling spacing does not drop color alternation, highlighting, etc.
    let isRubySpacingEnabled: Bool
    let isColorAlternationEnabled: Bool
    let isHighlightUnknownEnabled: Bool
    let unknownSegmentLocations: Set<Int>
    // UTF-16 segment start locations changed by the most recent LLM correction (pending confirmation).
    let changedSegmentLocations: Set<Int>
    // Subset of changedSegmentLocations where only the furigana reading changed (surface unchanged).
    let changedReadingLocations: Set<Int>
    // UTF-16 segment start locations on the line the LLM is processing right now.
    // Tinted indigo to distinguish "active line" from "pending change" (green).
    var inFlightSegmentLocations: Set<Int> = []
    // Hex strings for user-configured segment alternation colors. Empty string = use system default.
    let customEvenSegmentColorHex: String
    let customOddSegmentColorHex: String
    // Debug overlay flags — all false in production use.
    let debugFuriganaRects: Bool
    let debugHeadwordRects: Bool
    let debugHeadwordLineBands: Bool
    let debugFuriganaLineBands: Bool
    // Headword bisector: vertical line at the kanji-run geometric center.
    // Furigana bisector: vertical line at the ruby string geometric center.
    // Independent toggles so any misalignment between the two is directly visible.
    let debugBisectorHeadword: Bool
    let debugBisectorFurigana: Bool
    let debugEnvelopeRects: Bool
    // Draws a vertical reference line at textContainerInset.left and dumps numerical
    // positions for each line-start segment, so wide-ruby overhang and envelope
    // alignment can be diagnosed without relying on visual eyeballing of the
    // dashed envelope rects.
    let debugLeftInsetGuide: Bool
    let externalContentOffsetY: CGFloat
    let onScrollOffsetYChanged: (CGFloat) -> Void
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let furiganaGap: Double
    var textAlignment: NSTextAlignment = .natural
    var isScrollEnabled: Bool = true
}
