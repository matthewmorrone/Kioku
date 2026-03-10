import SwiftUI
import UIKit

final class RichTextEditorCoordinator: NSObject, UITextViewDelegate, NSLayoutManagerDelegate {
    @Binding var text: String
    @Binding var textSize: Double
    var onScrollOffsetYChanged: (CGFloat) -> Void
    var lastAppliedStyle: (
        textSize: Double,
        lineSpacing: Double,
        kerning: Double,
        isEditMode: Bool,
        isVisualEnhancementsEnabled: Bool,
        isColorAlternationEnabled: Bool,
        isHighlightUnknownEnabled: Bool
    )?
    private var pinchStartTextSize: Double?
    private var isApplyingExternalScroll = false
    private var segmentationNSRanges: [NSRange] = []

    // Connects the SwiftUI text binding to the UIKit delegate coordinator.
    init(text: Binding<String>, textSize: Binding<Double>, onScrollOffsetYChanged: @escaping (CGFloat) -> Void) {
        _text = text
        _textSize = textSize
        self.onScrollOffsetYChanged = onScrollOffsetYChanged
    }

    // Caches NSRange segment boundaries used to keep wrapped lines from splitting a token.
    func configureSegmentationRanges(_ segmentationRanges: [Range<String.Index>], in text: String) {
        segmentationNSRanges = segmentationRanges.compactMap { segmentRange in
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                return nil
            }

            return nsRange
        }
    }

    // Propagates text view edits into SwiftUI state after each user change.
    func textViewDidChange(_ textView: UITextView) {
        text = textView.text
    }

    // Publishes user-driven scroll offsets to the shared read/edit sync state.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isApplyingExternalScroll == false else {
            return
        }

        // Restricts shared offset updates to active edit interactions to avoid hidden-view scroll clamping.
        guard let textView = scrollView as? UITextView, textView.isEditable else {
            return
        }

        onScrollOffsetYChanged(scrollView.contentOffset.y)
    }

    // Applies external scroll offsets without re-emitting scroll callbacks.
    func applyExternalScrollIfNeeded(to textView: UITextView, targetOffsetY: CGFloat) {
        let minOffsetY = -textView.adjustedContentInset.top
        let maxOffsetY = max(minOffsetY, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        let clampedTargetY = min(max(targetOffsetY, minOffsetY), maxOffsetY)

        if abs(textView.contentOffset.y - clampedTargetY) < 0.5 {
            return
        }

        isApplyingExternalScroll = true
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedTargetY), animated: false)
        isApplyingExternalScroll = false
    }

    // Maps pinch gestures in the editor to persisted text size updates.
    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began {
            pinchStartTextSize = textSize
        }

        if recognizer.state == .changed, let pinchStartTextSize {
            let scaledTextSize = pinchStartTextSize * Double(recognizer.scale)
            let clampedTextSize = min(
                max(scaledTextSize, TypographySettings.textSizeRange.lowerBound),
                TypographySettings.textSizeRange.upperBound
            )
            textSize = clampedTextSize
        }

        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            pinchStartTextSize = nil
        }
    }

    // Rejects proposed wrap points that would split a lexical segment across two visual lines.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldBreakLineByWordBeforeCharacterAt charIndex: Int
    ) -> Bool {
        shouldAllowLineBreak(beforeCharacterAt: charIndex)
    }

    // Rejects hyphenation-based breaks inside segments so no fallback path can split a token.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int
    ) -> Bool {
        shouldAllowLineBreak(beforeCharacterAt: charIndex)
    }

    // Allows wrapping only at segment boundaries or outside tracked lexical ranges.
    private func shouldAllowLineBreak(beforeCharacterAt charIndex: Int) -> Bool {
        for nsRange in segmentationNSRanges {
            let lowerBound = nsRange.location
            let upperBound = nsRange.location + nsRange.length
            if charIndex > lowerBound && charIndex < upperBound {
                return false
            }
        }

        return true
    }
}
