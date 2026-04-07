import Foundation
import SwiftUI
import UIKit

// Stores renderer state so expensive furigana layout only runs when inputs change.
final class FuriganaTextRendererCoordinator: NSObject, UITextViewDelegate, NSTextLayoutManagerDelegate {

    @Binding private var textSize: Double
    var onScrollOffsetYChanged: (CGFloat) -> Void
    var onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    private var lastRenderSignature: Int?
    private var lastTextRenderSignature: Int?
    private var lastKnownBoundsWidth: CGFloat = 0
    private var pinchStartTextSize: Double?
    private var isApplyingExternalScroll = false
    private var segmentationNSRanges: [NSRange] = []
    private var wasActive = false
    private var lastPublishedScrollOffsetY: CGFloat?
    private var lastPlaybackAutoscrolledCueIndex: Int?
    private var hasLoggedMakeUIView = false
    private var hasLoggedFirstActiveUpdate = false
    private var hasLoggedFirstTextRender = false
    private var hasLoggedFirstOverlayApply = false
    private var hasLoggedFirstExhaustiveLayout = false

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
    // Also invalidates when the view transitions from zero to non-zero width, so that
    // a first render with no real frame doesn't permanently suppress furigana drawing.
    func shouldRender(for signature: Int, boundsWidth: CGFloat) -> Bool {
        let wasZero = lastKnownBoundsWidth == 0
        let isNonZero = boundsWidth > 0
        lastKnownBoundsWidth = boundsWidth
        // Invalidate when transitioning from zero to real width so a zero-frame first render doesn't permanently suppress furigana drawing.
        if wasZero && isNonZero {
            lastRenderSignature = nil
        }
        guard let lastRenderSignature else {
            return true
        }
        // Always re-render while bounds are zero so the next layout pass with a real frame retries.
        if boundsWidth == 0 {
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

    // Emits a startup marker once per renderer lifecycle for the given phase.
    func markStartupPhase(_ label: String) {
        StartupTimer.mark(label)
    }

    // Emits a startup marker only the first time the UIView is created.
    func markMakeUIViewIfNeeded() {
        guard hasLoggedMakeUIView == false else { return }
        hasLoggedMakeUIView = true
        StartupTimer.mark("FuriganaTextRenderer.makeUIView")
    }

    // Emits a startup marker only for the first active updateUIView call.
    func markFirstActiveUpdateIfNeeded(textLength: Int, segmentCount: Int, furiganaCount: Int) {
        guard hasLoggedFirstActiveUpdate == false else { return }
        hasLoggedFirstActiveUpdate = true
        StartupTimer.mark("FuriganaTextRenderer.updateUIView first active pass text=\(textLength) segments=\(segmentCount) furigana=\(furiganaCount)")
    }

    // Emits a startup marker only for the first base text rebuild.
    func markFirstTextRenderIfNeeded() {
        guard hasLoggedFirstTextRender == false else { return }
        hasLoggedFirstTextRender = true
        StartupTimer.mark("FuriganaTextRenderer first text render")
    }

    // Emits a startup marker only for the first overlay apply.
    func markFirstOverlayApplyIfNeeded(furiganaCount: Int) {
        guard hasLoggedFirstOverlayApply == false else { return }
        hasLoggedFirstOverlayApply = true
        StartupTimer.mark("FuriganaTextRenderer first overlay apply furigana=\(furiganaCount)")
    }

    // Emits a startup marker only for the first layout pass of a given type.
    func markFirstLayoutIfNeeded(exhaustive: Bool) {
        guard exhaustive, hasLoggedFirstExhaustiveLayout == false else { return }
        hasLoggedFirstExhaustiveLayout = true
        StartupTimer.mark("FuriganaTextRenderer first exhaustive layout")
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

    // Scrolls the active playback cue into a comfortable reading band when the cue changes.
    func applyPlaybackAutoscrollIfNeeded(to textView: UITextView, cueIndex: Int?, targetRect: CGRect?) {
        guard let cueIndex, let targetRect else {
            clearPlaybackAutoscrollState()
            return
        }

        guard lastPlaybackAutoscrolledCueIndex != cueIndex else {
            return
        }

        lastPlaybackAutoscrolledCueIndex = cueIndex
        let preferredVisibleY = textView.bounds.height * 0.32
        let targetOffsetY = targetRect.midY - preferredVisibleY
        applyExternalScrollIfNeeded(to: textView, targetOffsetY: targetOffsetY)
    }

    // Resets playback autoscroll tracking so the next cue change triggers a fresh scroll.
    func clearPlaybackAutoscrollState() {
        lastPlaybackAutoscrolledCueIndex = nil
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
