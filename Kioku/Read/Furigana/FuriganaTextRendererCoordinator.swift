import Foundation
import SwiftUI
import UIKit

// Stores renderer state so expensive furigana layout only runs when inputs change.
final class FuriganaTextRendererCoordinator: NSObject, UITextViewDelegate {

    @Binding private var textSize: Double
    var onScrollOffsetYChanged: (CGFloat) -> Void
    var onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    private var lastRenderSignature: Int?
    private var lastTextRenderSignature: Int?
    private var pinchStartTextSize: Double?
    private var isApplyingExternalScroll = false
    private var segmentationNSRanges: [NSRange] = []
    private var wasActive = false
    private var lastPublishedScrollOffsetY: CGFloat?

    // Stores shared state bindings used by the renderer coordinator.
    init(
        textSize: Binding<Double>,
        onScrollOffsetYChanged: @escaping (CGFloat) -> Void,
        onSegmentTapped: @escaping (Int?, CGRect?, UITextView?) -> Void
    ) {
        _textSize = textSize
        self.onScrollOffsetYChanged = onScrollOffsetYChanged
        self.onSegmentTapped = onSegmentTapped
        super.init()
    }

    // Caches NSRange segment boundaries used to map tap locations to lexical segments.
    func configureTapSegmentationRanges(_ segmentationRanges: [Range<String.Index>], in text: String) {
        segmentationNSRanges = segmentationRanges.compactMap { segmentRange in
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                return nil
            }
            return nsRange
        }
    }

    // Stores whether the renderer is currently active so transition-specific behavior can be applied.
    func updateActiveState(isActive: Bool) {
        wasActive = isActive
    }

    // Allows one external scroll sync when entering active read mode, then defers to user scrolling.
    func shouldApplyInitialExternalSync(isActive: Bool) -> Bool {
        defer {
            wasActive = isActive
        }

        return isActive && wasActive == false
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

    // Determines whether base text attributes need to be rebuilt for this signature.
    func shouldRenderText(for signature: Int) -> Bool {
        guard let lastTextRenderSignature else {
            return true
        }

        return lastTextRenderSignature != signature
    }

    // Persists the latest text-only render signature after base text is applied.
    func markTextRendered(signature: Int) {
        lastTextRenderSignature = signature
    }

    // Publishes user-driven scroll offsets to the shared read/edit sync state.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isApplyingExternalScroll == false else {
            return
        }

        publishScrollOffsetIfNeeded(scrollView.contentOffset.y, force: false)
    }

    // Publishes the final drag offset immediately so read/edit mode handoff stays accurate after user scrolling stops.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate == false {
            publishScrollOffsetIfNeeded(scrollView.contentOffset.y, force: true)
        }
    }

    // Publishes the final decelerated offset so overlay refresh catches the resting viewport position.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        publishScrollOffsetIfNeeded(scrollView.contentOffset.y, force: true)
    }

    // Applies external scroll offsets without triggering reciprocal updates.
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
        lastPublishedScrollOffsetY = clampedTargetY
        onScrollOffsetYChanged(clampedTargetY)
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

    // Publishes every scroll delta so furigana overlay refresh checks stay tightly coupled to text movement.
    private func publishScrollOffsetIfNeeded(_ offsetY: CGFloat, force: Bool) {
        _ = force

        lastPublishedScrollOffsetY = offsetY
        onScrollOffsetYChanged(offsetY)
    }

    // Maps a tap point to a segment location so read mode can highlight the tapped segment range.
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let textView = recognizer.view as? UITextView else {
            return
        }

        let tapPoint = recognizer.location(in: textView)
        guard let tappedCharacterRange = textView.characterRange(at: tapPoint) else {
            onSegmentTapped(nil, nil, textView)
            return
        }

        let tappedCharacterRect = textView.firstRect(for: tappedCharacterRange)
        let hitTestToleranceRect = tappedCharacterRect.insetBy(dx: -8, dy: -6)
        if tappedCharacterRect.isEmpty || hitTestToleranceRect.contains(tapPoint) == false {
            onSegmentTapped(nil, nil, textView)
            return
        }

        let textPosition = tappedCharacterRange.start

        let utf16Index = textView.offset(from: textView.beginningOfDocument, to: textPosition)
        if let tappedRange = resolveTappedRange(at: utf16Index) {
            guard isSelectableSegment(tappedRange, in: textView.text) else {
                onSegmentTapped(nil, nil, textView)
                return
            }

            onSegmentTapped(
                tappedRange.location,
                segmentRectInTextView(textView: textView, nsRange: tappedRange),
                textView
            )
            return
        }

        onSegmentTapped(nil, nil, textView)
    }

    // Resolves the segment range containing the tapped UTF-16 location.
    private func resolveTappedRange(at utf16Index: Int) -> NSRange? {
        if let exactRange = segmentationNSRanges.first(where: { NSLocationInRange(utf16Index, $0) }) {
            return exactRange
        }

        let priorIndex = utf16Index - 1
        if priorIndex >= 0 {
            return segmentationNSRanges.first(where: { NSLocationInRange(priorIndex, $0) })
        }

        return nil
    }

    // Rejects whitespace and punctuation-only segments so non-lexical segments never become selectable.
    private func isSelectableSegment(_ nsRange: NSRange, in sourceText: String) -> Bool {
        guard
            nsRange.location != NSNotFound,
            nsRange.length > 0,
            let range = Range(nsRange, in: sourceText)
        else {
            return false
        }

        let segmentText = sourceText[range]
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.contains { ignoredScalars.contains($0) == false }
    }

    // Resolves a segment rect in text-view coordinates for anchoring read-mode tooltips near tapped words.
    private func segmentRectInTextView(textView: UITextView, nsRange: NSRange) -> CGRect? {
        let documentStart = textView.beginningOfDocument
        guard
            let rangeStart = textView.position(from: documentStart, offset: nsRange.location),
            let rangeEnd = textView.position(from: rangeStart, offset: nsRange.length),
            let textRange = textView.textRange(from: rangeStart, to: rangeEnd)
        else {
            return nil
        }

        let segmentRect = textView.firstRect(for: textRange)
        if segmentRect.isEmpty {
            return nil
        }

        return segmentRect
    }

}
