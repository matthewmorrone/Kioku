import UIKit

// Render-signature helpers extracted from FuriganaTextRenderer so the main renderer stays under the
// 800-line warning threshold enforced by scripts/validate_invariants.sh. Signatures are read-only
// hash computations over the struct's input snapshot — keeping them here does not change behavior.
extension FuriganaTextRenderer {

    // Builds a stable signature so expensive rendering only runs when visual inputs actually change.
    func makeRenderSignature(for textView: UITextView) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            hasher.combine(nsRange.location)
            hasher.combine(nsRange.length)
        }
        hasher.combine(isLineWrappingEnabled)
        let furiganaLocations = furiganaBySegmentLocation.keys.sorted()
        for location in furiganaLocations {
            hasher.combine(location)
            hasher.combine(furiganaBySegmentLocation[location])
            hasher.combine(furiganaLengthBySegmentLocation[location] ?? 0)
        }
        hasher.combine(selectedSegmentLocation)
        hasher.combine(blankSelectedSegmentLocation)
        hasher.combine(selectedHighlightRangeOverride?.location)
        hasher.combine(selectedHighlightRangeOverride?.length)
        hasher.combine(playbackHighlightRangeOverride?.location)
        hasher.combine(playbackHighlightRangeOverride?.length)
        hasher.combine(activePlaybackCueIndex)
        hasher.combine(illegalMergeBoundaryLocation)
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(furiganaGap)
        hasher.combine(isActive)
        hasher.combine(isRubySpacingEnabled)
        hasher.combine(isColorAlternationEnabled)
        hasher.combine(isHighlightUnknownEnabled)
        for location in unknownSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedReadingLocations.sorted() {
            hasher.combine(location)
        }
        // Only width affects text wrapping and glyph positions. Height and contentSize are derived
        // outputs — including them would trigger re-renders on every layout-driven contentSize
        // patch, and externalContentOffsetY changes on every scroll tick which would force O(N)
        // firstRect queries per frame. The overlay is a subview in content-space so its drawn
        // content is correct regardless of the current scroll position.
        hasher.combine(textView.bounds.width)
        // Debug flag changes must invalidate the overlay so toggling takes effect immediately.
        hasher.combine(debugFuriganaRects)
        hasher.combine(debugHeadwordRects)
        hasher.combine(debugHeadwordLineBands)
        hasher.combine(debugFuriganaLineBands)
        hasher.combine(debugBisectors)
        hasher.combine(debugEnvelopeRects)
        hasher.combine(debugLeftInsetGuide)
        hasher.combine(customEvenSegmentColorHex)
        hasher.combine(customOddSegmentColorHex)
        return hasher.finalize()
    }

    // Builds a stable signature for read-mode base text changes that require a full
    // attributedText reassignment + relayout. Excludes anything that only affects per-segment
    // foreground colors (segmentation, alternation, highlights, custom colors) — those go
    // through makeStyleAttributesSignature and apply via in-place textStorage mutation, which
    // doesn't perturb glyph layout or contentSize.
    //
    // Furigana entries STAY here because the base-text inset/exclusion pass that produces
    // ruby spacing depends on their content — switching a reading to a longer one needs more
    // left-inset to keep the wider ruby on-screen. Without these entries, reading overrides
    // only updated the overlay (which uses makeRenderSignature) and ruby spacing stayed stale
    // until a setting toggle.
    func makeBaseTextRenderSignature(for textView: UITextView) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(isLineWrappingEnabled)
        hasher.combine(isVisualEnhancementsEnabled)
        hasher.combine(isRubySpacingEnabled)
        let furiganaLocations = furiganaBySegmentLocation.keys.sorted()
        for location in furiganaLocations {
            hasher.combine(location)
            hasher.combine(furiganaBySegmentLocation[location])
            hasher.combine(furiganaLengthBySegmentLocation[location] ?? 0)
        }
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(furiganaGap)
        hasher.combine(isActive)
        // Width affects text wrapping and therefore which segments sit at line-start positions.
        // Height and contentSize are derived outputs: including them here causes re-renders every
        // time the layout pass patches contentSize, creating an attribution→layout→patch→re-render
        // oscillation that resets exclusion paths and produces visible alignment jitter.
        hasher.combine(textView.bounds.width)
        return hasher.finalize()
    }

    // Builds a signature for changes that only affect per-segment foreground colors and
    // shadows — segmentation boundaries, color-alternation toggle, unknown/changed highlights,
    // custom user colors. Triggers an in-place textStorage attribute mutation rather than a
    // full attributedText reassignment, so split/merge no longer reflows the entire view.
    func makeStyleAttributesSignature() -> Int {
        var hasher = Hasher()
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            hasher.combine(nsRange.location)
            hasher.combine(nsRange.length)
        }
        hasher.combine(isColorAlternationEnabled)
        hasher.combine(isHighlightUnknownEnabled)
        for location in unknownSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedReadingLocations.sorted() {
            hasher.combine(location)
        }
        hasher.combine(customEvenSegmentColorHex)
        hasher.combine(customOddSegmentColorHex)
        return hasher.finalize()
    }
}
