import SwiftUI
import UIKit

final class RichTextEditorCoordinator: NSObject, UITextViewDelegate {
    @Binding var text: String
    @Binding var textSize: Double
    var onScrollOffsetYChanged: (CGFloat) -> Void
    var lastAppliedStyle: (textSize: Double, lineSpacing: Double, kerning: Double, isEditMode: Bool)?
    private var pinchStartTextSize: Double?
    private var isApplyingExternalScroll = false

    // Connects the SwiftUI text binding to the UIKit delegate coordinator.
    init(text: Binding<String>, textSize: Binding<Double>, onScrollOffsetYChanged: @escaping (CGFloat) -> Void) {
        _text = text
        _textSize = textSize
        self.onScrollOffsetYChanged = onScrollOffsetYChanged
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
}
