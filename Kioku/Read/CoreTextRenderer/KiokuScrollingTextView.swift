import SwiftUI
import UIKit

// UIScrollView host for the CoreText content view. Owns layout passing — the content
// view's intrinsicContentSize is height-only, so we drive width from the scroll view's
// bounds and read height back to set contentSize.
final class KiokuScrollingTextView: UIScrollView, UIScrollViewDelegate {

    let contentView = KiokuCoreTextView()

    // True between updateUIView calls while the renderer was active. Lives on the UIView (not
    // the SwiftUI struct, which is recreated every body eval) so the inactive→active edge —
    // "edit mode just exited" — survives across updates. See updateUIView.
    var wasActiveInLastUpdate = false

    // Reports every contentOffset change (user pan, deceleration, programmatic scrolls) so the
    // host can mirror the live offset for edit↔view scroll sync. nil for call sites that opted
    // out (lyrics/song cards).
    var onScrollOffsetYChanged: ((CGFloat) -> Void)?

    // Reentrancy guard so an externally-applied offset doesn't echo back out through
    // `onScrollOffsetYChanged` — same pattern as RichTextEditorCoordinator.
    private var isApplyingExternalScrollOffset = false
    // Dev-only debug overlay sibling. Lives at the same coordinate origin as the
    // text content view so all rect math uses one space (no conversions). Hidden
    // when no flags are set so it's a no-op for normal users.
    let debugOverlay = KiokuDebugOverlayView()

    // Segment NSRanges snapshot — kept in sync with the most recent attributed string by
    // KiokuCoreTextRendererView.updateUIView so tap-handling can stay O(segments) without
    // re-bridging Swift Range<String.Index> on every tap.
    var cachedSegmentNSRanges: [NSRange] = []

    // Hash of the typography-affecting inputs handed to the attributed-string builder on the
    // last successful build. updateUIView consults this to skip the build + setAttributedString
    // chain (CT rebuilds the entire line block on every set) when only selection/highlight
    // state changed — those don't enter the builder and don't need a re-typeset.
    var lastTypographyFingerprint: Int?

    // Mirror of the representable's `textAlignment` so `layoutSubviews` can re-apply
    // centering shifts after a width change without depending on SwiftUI to re-fire
    // `updateUIView`. Set from `KiokuCoreTextRendererView.updateUIView` on every body
    // re-evaluation.
    //
    // Why this exists: `updateUIView` reads `bounds.width` to compute centering, but
    // it runs in the SwiftUI update phase — before the first `layoutSubviews`, when
    // `bounds.width` is still 0. That left the shifts dict empty and the active cue
    // in LyricsView flush-left inside its centered card. Re-running the shift block
    // from `layoutSubviews` (where bounds.width is correct) fixes it.
    var textAlignment: NSTextAlignment = .natural

    // Forwarded from the content view's tap recognizer. UTF-16 character index of the tap,
    // or nil when the tap landed in empty space (no glyph under the point) — callers
    // route nil into the "clear selection" branch.
    var onCharacterTapped: ((Int?) -> Void)? {
        didSet { wireContentTap() }
    }

    // Forwarded from the content view's long-press recognizer, same contract as
    // `onCharacterTapped`. nil until a host wires it (only the karaoke card does).
    var onCharacterLongPressed: ((Int?) -> Void)? {
        didSet { wireContentLongPress() }
    }

    // Pinch begin/change/end callbacks. Caller (the SwiftUI host) decides what to do
    // with the scale — typically multiply the starting text-size by the cumulative
    // recognizer.scale and clamp to the typography range.
    var onPinchBegan: (() -> Void)?
    var onPinchChanged: ((CGFloat) -> Void)?
    var onPinchEnded: (() -> Void)?
    private var pinchRecognizer: UIPinchGestureRecognizer?

    // Hosts the CoreText content view and a sibling debug overlay at the same coordinate
    // origin so all rect math uses one space.
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(contentView)
        addSubview(debugOverlay)
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        // Self-delegation for scroll reporting. UIScrollView's pan-driven scrolling moves
        // bounds.origin directly (it does not go through the contentOffset setter), so a
        // property observer can't see it — the delegate callback is the reliable hook.
        delegate = self
        // UIScrollView defaults to delaying content touches by ~150ms so it can decide
        // whether the gesture is a scroll. For the read view this turns every tap into
        // a perceptible "lag" — the pan recognizer still claims real drags, so we lose
        // nothing by delivering touches to the content view immediately.
        delaysContentTouches = false
        canCancelContentTouches = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch
    }

    // Dispatches the pinch state to the matching callback. `.changed` passes the
    // cumulative scale factor (relative to gesture start), so the host can compute the
    // new text size as `startTextSize * scale`.
    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began: onPinchBegan?()
        case .changed: onPinchChanged?(recognizer.scale)
        case .ended, .cancelled, .failed: onPinchEnded?()
        default: break
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Snapshot of the inputs needed to rebuild the debug overlay's geometry. Stored on
    // the scroll view so `layoutSubviews` can refresh the overlay after a width change
    // (which causes the engine to relayout); otherwise the overlay would keep stale
    // geometry from the first `updateUIView` call — which is the case for any
    // representable whose initial bounds are zero (e.g. SettingsPreviewRenderer).
    struct DebugGeometryInputs {
        var lexicalSegmentNSRanges: [NSRange] = []
        var furiganaByLocation: [Int: String] = [:]
        var furiganaLengthByLocation: [Int: Int] = [:]
        var baseFont: UIFont = UIFont.systemFont(ofSize: 18)
        var furiganaFont: UIFont = UIFont.systemFont(ofSize: 9)
        var isFuriganaVisible: Bool = true
    }
    var debugGeometryInputs = DebugGeometryInputs() {
        didSet { recomputeDebugGeometry() }
    }

    // Rebuilds the debug overlay's segment + line geometry from the stored inputs and
    // the engine's current layout state. Called from `updateUIView` (when inputs
    // arrive) AND from `layoutSubviews` (so width-driven engine relayouts propagate
    // to the overlay without needing SwiftUI to re-evaluate the parent body).
    func recomputeDebugGeometry() {
        let inputs = debugGeometryInputs
        let nsText = contentView.layoutEngine.attributedString.string as NSString
        var firstRectByRange: [NSRange: CGRect] = [:]
        for range in inputs.lexicalSegmentNSRanges {
            guard let r = contentView.layoutEngine.firstRect(forCharacterRange: range) else { continue }
            firstRectByRange[range] = r
        }
        var kanjiRunRectByLocation: [Int: CGRect] = [:]
        for (kanjiLoc, _) in inputs.furiganaByLocation {
            guard let kLen = inputs.furiganaLengthByLocation[kanjiLoc], kLen > 0 else { continue }
            guard kanjiLoc + kLen <= nsText.length else { continue }
            let kRange = NSRange(location: kanjiLoc, length: kLen)
            guard let r = contentView.layoutEngine.firstRect(forCharacterRange: kRange) else { continue }
            let kanjiSurface = nsText.substring(with: kRange)
            let glyphWidth = ceil((kanjiSurface as NSString).size(withAttributes: [.font: inputs.baseFont]).width)
            kanjiRunRectByLocation[kanjiLoc] = CGRect(
                x: r.origin.x,
                y: r.origin.y,
                width: min(r.width, glyphWidth),
                height: r.height
            )
        }
        let engineLines = contentView.layoutEngine.lines
        let geometryInputs = KiokuDebugOverlayGeometry.Inputs(
            firstRectByNSRange: firstRectByRange,
            segmentNSRanges: inputs.lexicalSegmentNSRanges,
            kanjiRunRectByLocation: kanjiRunRectByLocation,
            kanjiRunLengthByLocation: inputs.furiganaLengthByLocation,
            readingByLocation: inputs.furiganaByLocation,
            baseFont: inputs.baseFont,
            furiganaFont: inputs.furiganaFont,
            lineFrames: engineLines.map { $0.frame },
            furiganaBandHeight: ceil(inputs.furiganaFont.lineHeight),
            isFuriganaVisible: inputs.isFuriganaVisible
        )
        debugOverlay.segmentGeometry = KiokuDebugOverlayGeometry.segments(geometryInputs)
        debugOverlay.lineGeometry = KiokuDebugOverlayGeometry.lines(geometryInputs)
        debugOverlay.leftInsetX = contentView.layoutEngine.contentInset.left
    }

    // Sizes the content view to fill the width and grow to natural height; overlay tracks
    // the same frame so its rect math stays aligned with the engine output. ALSO triggers
    // a debug-geometry refresh — the engine relayouts when width changes, and the
    // overlay's geometry depends on engine state, so it has to refresh in lockstep.
    override func layoutSubviews() {
        super.layoutSubviews()
        let viewportWidth = bounds.width
        // Lay the engine out against the viewport width; sizeThatFits feeds back the height.
        let height = contentView.sizeThatFits(CGSize(width: viewportWidth, height: .greatestFiniteMagnitude)).height
        // The engine's own contentSize.width is the natural content width. When line
        // wrapping is OFF the packer lets segments overflow the right edge instead of
        // breaking, so this exceeds the viewport — size the content view and scroll content
        // to that natural width so the overflowing columns become reachable by a horizontal
        // pan (UIScrollView engages horizontal scrolling automatically once
        // contentSize.width > bounds.width). When wrapping is ON the natural width collapses
        // back to the viewport (lines break to fit), so `max` returns viewportWidth and only
        // vertical scrolling remains — no behavior change to the wrapping path itself.
        let contentWidth = max(viewportWidth, contentView.layoutEngine.contentSize.width)
        contentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: height)
        debugOverlay.frame = contentView.frame
        contentSize = CGSize(width: contentWidth, height: height)
        // Re-apply centering shifts now that `bounds.width` (and therefore the engine's
        // widthConstraint, set by contentView.layoutSubviews above) is correct. The
        // updateUIView path may have run before any layout pass with bounds.width=0; in
        // that case its shift dict was empty and lines fell back to left-aligned at
        // contentInset.left. This call closes that window. Engine's
        // `setLineOriginShifts` is a no-op when the dict is unchanged, so when bounds
        // were already correct in updateUIView this costs nothing.
        applyCenteringShiftsIfNeeded()
        // Recompute debug geometry from the engine's now-current layout state. Without
        // this, a view whose first `updateUIView` ran with width=0 (e.g. a representable
        // inside a Form Section) would keep an empty `segmentGeometry` even after layout
        // populated valid placements.
        recomputeDebugGeometry()
    }

    // Computes per-line X shifts that center each line within the available width
    // (bounds.width minus the engine's horizontal contentInset). Returns an empty dict
    // when bounds aren't yet valid (width ≤ inset) or when textAlignment isn't `.center`,
    // so callers can fold the result into a broader shift map without an additional
    // guard. Shared between `updateUIView` (initial path) and `layoutSubviews` (post-
    // layout re-application).
    func computeCenteringShifts() -> [Int: CGFloat] {
        guard textAlignment == .center else { return [:] }
        let engineLines = contentView.layoutEngine.lines
        let inset = contentView.layoutEngine.contentInset
        let availableWidth = bounds.width - inset.left - inset.right
        guard availableWidth > 0 else { return [:] }
        var shifts: [Int: CGFloat] = [:]
        for (index, line) in engineLines.enumerated() {
            // Shift to center even when the line overflows (extra < 0). With
            // isRubySpacingEnabled, packed-layout line widths can exceed availableWidth —
            // without a negative-shift branch the line falls back to left-aligned at
            // inset.left, which reads as "centering broke." Sub-pixel jitter is filtered.
            let extra = availableWidth - line.width
            if abs(extra) > 0.5 {
                shifts[index] = extra / 2
            }
        }
        return shifts
    }

    // Layout-time entry point that recomputes and pushes centering shifts to the engine.
    // Skipped when the view isn't using `.center` alignment so the wide-ruby shift map
    // installed by updateUIView isn't clobbered. Safe to call repeatedly — the engine's
    // `setLineOriginShifts` short-circuits when the dict is unchanged.
    private func applyCenteringShiftsIfNeeded() {
        guard textAlignment == .center else { return }
        let shifts = computeCenteringShifts()
        // When the engine has no lines yet (e.g. zero-width relayout hasn't run), shifts
        // is empty — pushing an empty dict would erase a stale-but-valid map from a
        // prior layout pass. Only push when we actually have something to apply.
        guard shifts.isEmpty == false else { return }
        contentView.setLineOriginShifts(shifts)
    }

    // Mirrors every offset change out to the host (reference-type memo on the ReadView side,
    // so this costs no SwiftUI invalidation per frame). Skipped while WE are applying an
    // external offset, so the apply can't echo back.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isApplyingExternalScrollOffset == false else { return }
        onScrollOffsetYChanged?(contentOffset.y)
    }

    // Applies an externally-tracked offset (the editor's last scroll position), clamped to the
    // current content bounds — same clamping/tolerance contract as
    // RichTextEditorCoordinator.applyExternalScrollIfNeeded so the two directions of the
    // edit↔view handoff behave identically.
    func applyExternalScrollOffsetY(_ targetOffsetY: CGFloat) {
        let minOffsetY = -adjustedContentInset.top
        let maxOffsetY = max(minOffsetY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let clampedTargetY = min(max(targetOffsetY, minOffsetY), maxOffsetY)
        guard abs(contentOffset.y - clampedTargetY) >= 0.5 else { return }
        isApplyingExternalScrollOffset = true
        setContentOffset(CGPoint(x: contentOffset.x, y: clampedTargetY), animated: false)
        isApplyingExternalScrollOffset = false
    }

    // Translates a rect from the content view's coordinate space to this scroll-view-relative
    // space. Callers can then `view.convert(_:to:)` further up if needed. Right now the
    // content view is anchored at (0,0) inside this scroll view so the rect is unchanged,
    // but having the indirection keeps callers safe against future host changes.
    func convertContentRectToHost(_ rect: CGRect) -> CGRect {
        convert(rect, from: contentView)
    }

    // Tracks the last range we scrolled to so we don't fight the user when they scroll away
    // and the playback range hasn't changed.
    private var lastScrolledRange: NSRange?

    // Token of the last scroll-to-top request we honored. A change signals "a new note was
    // opened," so we reset to the top exactly once rather than continuously pinning the
    // offset (which would fight the user's own scrolling).
    private var lastScrollToTopToken: Int?

    // Resets the scroll position to the top of the content when `token` differs from the last
    // one honored; a no-op on repeat tokens. The top (−inset.top) is a stable target
    // independent of contentSize, so this is safe to apply even before the new note's content
    // has finished laying out. Also clears the playback-scroll memo so a same-range cue scroll
    // can still fire afterward for the freshly opened note.
    func scrollToTopIfTokenChanged(_ token: Int) {
        guard lastScrollToTopToken != token else { return }
        lastScrollToTopToken = token
        setContentOffset(CGPoint(x: 0, y: -adjustedContentInset.top), animated: false)
        lastScrolledRange = nil
    }

    // Scrolls so the first rect covering `range` sits `anchorFraction` from the top of the
    // viewport. Idempotent against repeated calls with the same range.
    func scrollRangeIntoView(_ range: NSRange, anchorFraction: CGFloat) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        if lastScrolledRange == range { return }
        // The content view's layout has to be current before queries make sense.
        layoutIfNeeded()
        guard let rect = contentView.layoutEngine.firstRect(forCharacterRange: range) else { return }
        let viewportHeight = bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
        let targetY = rect.midY - viewportHeight * anchorFraction
        let maxY = max(0, contentSize.height - bounds.height)
        let clamped = max(0, min(targetY, maxY))
        setContentOffset(CGPoint(x: contentOffset.x, y: clamped), animated: true)
        lastScrolledRange = range
    }

    // Hooks the content view's tap recognizer to the host's character-tap forwarder.
    // Re-runs whenever `onCharacterTapped` is set so the closure capture stays current.
    private func wireContentTap() {
        contentView.onTap = { [weak self] characterIndex, _ in
            self?.onCharacterTapped?(characterIndex)
        }
    }

    // Hooks the content view's long-press recognizer to the host's forwarder.
    // Re-runs whenever `onCharacterLongPressed` is set so the closure capture stays current.
    private func wireContentLongPress() {
        contentView.onLongPress = { [weak self] characterIndex, _ in
            self?.onCharacterLongPressed?(characterIndex)
        }
    }
}
