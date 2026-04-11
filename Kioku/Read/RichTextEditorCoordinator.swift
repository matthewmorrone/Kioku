import SwiftUI
import UIKit

final class RichTextEditorCoordinator: NSObject, UITextViewDelegate, NSTextLayoutManagerDelegate {
    @Binding var text: String
    @Binding var textSize: Double
    var onScrollOffsetYChanged: (CGFloat) -> Void
    var lastAppliedStyle: RichTextEditorStyleSignature?
    var lastRenderedText = ""
    private var pinchStartTextSize: Double?
    private var isApplyingExternalScroll = false
    private var segmentationNSRanges: [NSRange] = []

    // Connects the SwiftUI text binding to the UIKit delegate coordinator.
    init(text: Binding<String>, textSize: Binding<Double>, onScrollOffsetYChanged: @escaping (CGFloat) -> Void) {
        _text = text
        _textSize = textSize
        self.onScrollOffsetYChanged = onScrollOffsetYChanged
    }

    // Caches NSRange segment boundaries used to keep wrapped lines from splitting a segment.
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
        let latestText = textView.text ?? ""
        text = latestText
        lastRenderedText = latestText
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

    // Prevents line breaks from splitting a segment mid-character so the full headword
    // (including okurigana) always wraps to the next line as an atomic unit.
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        shouldBreakLineBefore location: any NSTextLocation,
        hyphenating: Bool
    ) -> Bool {
        guard let tcm = textLayoutManager.textContentManager else { return true }
        let docStart = tcm.documentRange.location
        let offset = tcm.offset(from: docStart, to: location)
        guard offset != NSNotFound else { return true }
        // Allow the break only if this offset is not in the interior of any segment.
        // Interior means: offset > segment.location && offset < segment.location + segment.length.
        for nsRange in segmentationNSRanges {
            if offset > nsRange.location && offset < nsRange.location + nsRange.length {
                return false
            }
        }
        return true
    }

}
