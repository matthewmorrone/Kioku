import Foundation
import SwiftUI
import UIKit

// Stores renderer state so expensive furigana layout only runs when inputs change.
final class FuriganaTextRendererCoordinator {
    @Binding private var textSize: Double
    private var lastRenderSignature: Int?
    private var pinchStartTextSize: Double?

    // Stores shared state bindings used by the renderer coordinator.
    init(textSize: Binding<Double>) {
        _textSize = textSize
    }

    // Determines whether a new render pass is needed for the provided signature.
    func shouldRender(for signature: Int) -> Bool {
        guard let lastRenderSignature else {
            return true
        }

        return lastRenderSignature != signature
    }

    // Persists the latest render signature after a successful render pass.
    func markRendered(signature: Int) {
        lastRenderSignature = signature
    }

    // Maps pinch gestures in read mode to persisted text-size updates.
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
