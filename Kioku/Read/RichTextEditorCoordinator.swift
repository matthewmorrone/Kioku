import SwiftUI
import UIKit

final class RichTextEditorCoordinator: NSObject, UITextViewDelegate {
    @Binding var text: String
    @Binding var textSize: Double
    var lastAppliedStyle: (textSize: Double, lineSpacing: Double, kerning: Double, isEditMode: Bool)?
    private var pinchStartTextSize: Double?

    // Connects the SwiftUI text binding to the UIKit delegate coordinator.
    init(text: Binding<String>, textSize: Binding<Double>) {
        _text = text
        _textSize = textSize
    }

    // Propagates text view edits into SwiftUI state after each user change.
    func textViewDidChange(_ textView: UITextView) {
        text = textView.text
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
