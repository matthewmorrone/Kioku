import UIKit

// TextKit-geometry helpers extracted from FuriganaTextRenderer so the main renderer stays under the
// 800-line warning threshold. All functions follow the one-coordinate-pipeline invariant in
// AGENTS.md §9: TextKit rect → convert using textContainerInset → render in text-view coordinates.
extension FuriganaTextRenderer {

    // Resolves the visual segment rectangle used to anchor furigana over the same glyph layout.
    func segmentRectInTextView(textView: UITextView, nsRange: NSRange) -> CGRect? {
        guard
            nsRange.location != NSNotFound,
            nsRange.length > 0,
            let textRange = textRange(in: textView, nsRange: nsRange)
        else {
            return nil
        }

        ensureTextLayout(for: textView, coordinator: nil)
        let segmentRect = textView.firstRect(for: textRange)
        guard segmentRect.isNull == false, segmentRect.isInfinite == false, segmentRect.isEmpty == false else {
            return nil
        }

        return segmentRect
    }

    // Keeps the text container in wrapped or horizontal-scroll layout based on the display option.
    func configureWrapping(for textView: UITextView) {
        let contentInsets = textView.textContainerInset
        let availableWidth = max(
            textView.bounds.width - contentInsets.left - contentInsets.right,
            0
        )
        textView.textContainer.widthTracksTextView = isLineWrappingEnabled
        textView.textContainer.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping
        textView.textContainer.size = CGSize(
            width: isLineWrappingEnabled ? availableWidth : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    // Resolves a thin rect at a UTF-16 boundary for illegal-merge flash feedback.
    func boundaryIndicatorRectInTextView(textView: UITextView, boundaryUTF16Location: Int) -> CGRect? {
        let textLength = (textView.text as NSString).length
        guard boundaryUTF16Location > 0, boundaryUTF16Location < textLength else {
            return nil
        }

        ensureTextLayout(for: textView, coordinator: nil)
        guard
            let previousTextRange = textRange(in: textView, nsRange: NSRange(location: boundaryUTF16Location - 1, length: 1)),
            let nextTextRange = textRange(in: textView, nsRange: NSRange(location: boundaryUTF16Location, length: 1))
        else {
            return nil
        }

        let previousRect = textView.firstRect(for: previousTextRange)
        let nextRect = textView.firstRect(for: nextTextRange)
        guard
            previousRect.isNull == false,
            previousRect.isInfinite == false,
            previousRect.isEmpty == false,
            nextRect.isNull == false,
            nextRect.isInfinite == false,
            nextRect.isEmpty == false
        else {
            return nil
        }

        let lineTopY = min(previousRect.minY, nextRect.minY)
        let lineBottomY = max(previousRect.maxY, nextRect.maxY)
        return CGRect(
            x: nextRect.minX - 1.5,
            y: lineTopY - 3,
            width: 3,
            height: max((lineBottomY - lineTopY) + 6, 16)
        )
    }

    // Forces lazy TextKit layout to complete before any geometry is queried for annotations.
    func ensureTextLayout(for textView: UITextView, coordinator: FuriganaTextRendererCoordinator?, exhaustive: Bool = false) {
        coordinator?.markFirstLayoutIfNeeded(exhaustive: exhaustive)
        if exhaustive {
            StartupTimer.measure("FuriganaTextRenderer.ensureTextLayout.exhaustive") {
                guard let textLayoutManager = textView.textLayoutManager,
                      let documentRange = textLayoutManager.textContentManager?.documentRange else {
                    return
                }
                // TextKit 2's textViewportLayoutController caps ensureLayout at the textView's
                // current bounds.height (+ a small overscan). When new content needs more height
                // than the prior layout — e.g. the Settings preview right after a font-size bump,
                // where bounds is still the smaller pre-resize value — fragments past the cap
                // never get laid out, firstRect returns nil for those ranges, and the trailing
                // line's furigana silently drops out. Temporarily inflate bounds.height to a very
                // large value so the viewport extends, force layout, then restore. After this,
                // fragments exist and firstRect works regardless of the actual bounds.
                let originalBounds = textView.bounds
                textView.bounds = CGRect(
                    x: originalBounds.origin.x,
                    y: originalBounds.origin.y,
                    width: originalBounds.width,
                    height: 1_000_000
                )
                textLayoutManager.ensureLayout(for: documentRange)
                // With bounds.height inflated above, ensureLayout realizes every fragment.
                // Read the last fragment's maxY in O(1) via a reverse-from-end walk that stops
                // after the first hit — a forward walk over the whole document was the dominant
                // cost on toggles (O(N) per call, multiple calls per toggle).
                var maxLayoutY: CGFloat = 0
                textLayoutManager.enumerateTextLayoutFragments(from: documentRange.endLocation, options: [.reverse]) { fragment in
                    maxLayoutY = fragment.layoutFragmentFrame.maxY
                    return false
                }
                textView.bounds = originalBounds
                let requiredHeight = textView.textContainerInset.top + maxLayoutY + textView.textContainerInset.bottom
                if requiredHeight > textView.contentSize.height {
                    textView.contentSize = CGSize(width: textView.contentSize.width, height: requiredHeight)
                }
            }
        } else {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        if exhaustive {
            StartupTimer.mark("FuriganaTextRenderer exhaustive layout finished")
        }
        textView.layoutIfNeeded()
    }

    // Converts a UTF-16 range into the UITextInput range used by TextKit 2 geometry queries.
    func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        let documentStart = textView.beginningOfDocument
        guard
            let rangeStart = textView.position(from: documentStart, offset: nsRange.location),
            let rangeEnd = textView.position(from: rangeStart, offset: nsRange.length)
        else {
            return nil
        }

        return textView.textRange(from: rangeStart, to: rangeEnd)
    }

    // Finds the selected segment NSRange so overlay highlighting can target the tapped segment.
    func selectedSegmentNSRange(in sourceText: String) -> NSRange? {
        if let selectedHighlightRangeOverride,
           selectedHighlightRangeOverride.location != NSNotFound,
           selectedHighlightRangeOverride.length > 0,
           selectedHighlightRangeOverride.upperBound <= (sourceText as NSString).length {
            return selectedHighlightRangeOverride
        }

        guard let selectedSegmentLocation else {
            return nil
        }

        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: sourceText)
            if nsRange.location == selectedSegmentLocation, nsRange.length > 0 {
                return nsRange
            }
        }

        return nil
    }

    // Validates and returns the playback highlight range, guarding against stale overrides that extend past the current text.
    func playbackHighlightNSRange(in sourceText: String) -> NSRange? {
        guard let playbackHighlightRangeOverride,
              playbackHighlightRangeOverride.location != NSNotFound,
              playbackHighlightRangeOverride.length > 0,
              playbackHighlightRangeOverride.upperBound <= (sourceText as NSString).length else {
            return nil
        }

        return playbackHighlightRangeOverride
    }

    // Measures text width for furigana label sizing so readings don't collapse into truncation glyphs.
    func measureTextWidth(_ value: String, font: UIFont, kerning: Double) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: kerning,
        ]
        return ceil((value as NSString).size(withAttributes: attributes).width)
    }

    // Returns the visual extent of `value` as the textView actually renders it: glyph widths plus
    // (n - 1) intra-character kerns, matching the user's configured kerning. Used by all
    // ruby-centering / bisector / envelope math so positioning stays accurate when kerning > 0.
    // Computed by measuring with kerning then subtracting the trailing kern that NSAttributedString
    // includes after the last character (a known UIKit quirk that would otherwise inflate the width
    // by one full kern unit beyond the rightmost glyph edge).
    func kernedVisualWidth(of value: String, font: UIFont) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        let kernedTotal = measureTextWidth(value, font: font, kerning: kerning)
        return max(0, kernedTotal - CGFloat(kerning))
    }
}
