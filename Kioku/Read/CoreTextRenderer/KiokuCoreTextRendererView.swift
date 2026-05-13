import SwiftUI
import UIKit

// SwiftUI bridge for the experimental CoreText Read renderer. Mounted in place of
// `FuriganaTextRenderer` when DebugSettings.useCoreTextRenderer is on.
//
// Scope of this first integration step: render plain text (no segment overlays, no
// per-segment ruby attributes — CTRubyAnnotation drawn directly via CT) inside a
// UIScrollView so the renderer can be A/B'd against the TK2 path for layout, scroll
// physics, and contentSize parity. Ruby/segment overlays will be wired in subsequent
// passes once the geometry adapter is in place.
// Pure helper: maps a UTF-16 character index to the first segment range that contains it.
// Extracted from the view so it can be unit-tested without a UIView under test.
enum KiokuCoreTextSegmentResolver {
    // Returns the first segment NSRange that contains the given UTF-16 character index,
    // or nil when the index falls outside every segment (whitespace, punctuation gap).
    static func segmentRange(forCharacterIndex characterIndex: Int, in ranges: [NSRange]) -> NSRange? {
        ranges.first { NSLocationInRange(characterIndex, $0) }
    }
}

// Ownership: owned by ReadView (parent). Lifetime tied to the read-mode editorView
// container. Holds value-typed props only; no @State / @ObservedObject.
struct KiokuCoreTextRendererView: UIViewRepresentable {

    let text: String
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isFuriganaVisible: Bool
    let isVisualEnhancementsEnabled: Bool
    let isColorAlternationEnabled: Bool
    // Binding so the pinch gesture can write back the user-scaled text size, persisting
    // through the AppStorage-backed `textSize` setting on the read view. Stored as
    // Double to match the @AppStorage type; cast to CGFloat at use sites.
    @Binding var textSize: Double
    let lineSpacing: CGFloat
    let kerning: CGFloat
    let evenSegmentColor: UIColor
    let oddSegmentColor: UIColor
    let isLineWrappingEnabled: Bool
    let isRubySpacingEnabled: Bool
    // Optional highlight ranges (UTF-16 against `text`). The renderer fills a rounded
    // background under each range. Playback paints on top of selection so a playing tapped
    // segment shows the playback color.
    let selectedHighlightRange: NSRange?
    let playbackHighlightRange: NSRange?
    let selectionHighlightColor: UIColor
    let playbackHighlightColor: UIColor
    // Unknown-segment highlight: locations whose surface isn't in the dictionary. Each gets
    // the unknown color overlaid on its NSRange. Empty = feature off.
    let unknownSegmentLocations: Set<Int>
    let isHighlightUnknownEnabled: Bool
    let unknownSegmentColor: UIColor
    // Dev-only debug overlay toggles. The overlay view stays mounted always but only
    // draws when a flag is on, so this is zero-cost for normal users.
    let debugFlags: KiokuDebugOverlayView.Flags
    // Marker for an illegal merge boundary — drawn as a red bar at that segment's
    // bisector when set. Nil = no marker.
    let illegalMergeLocation: Int?
    // Reports tapped segment by NSRange location (UTF-16) and its first-line rect in
    // renderer-local coordinates. `nil` means the tap landed outside any selectable segment
    // and the caller should clear selection.
    var onSegmentTapped: (Int?, CGRect?) -> Void = { _, _ in }

    // When false, the host scroll view disables user scrolling. Used by the LyricsView
    // active-cue card, which renders the full noteText but pins the viewport to one cue
    // via `playbackHighlightRange`-driven auto-scroll — letting the user scroll would let
    // them drift the card off the active line.
    var isScrollEnabled: Bool = true

    // Coordinator holds the textSize captured at the start of a pinch so each .changed
    // delta computes against the original, not the live (already-mutated) value. Also
    // forwards SwiftUI bindings to the UIView's closures.
    final class Coordinator {
        var pinchStartTextSize: Double = 0
    }

    // Required by UIViewRepresentable when a Coordinator is needed; we use it to hold
    // pinch-gesture state that has to survive between .began and .changed events.
    func makeCoordinator() -> Coordinator { Coordinator() }

    // Builds the scroll-view host + content view once. Tap forwarding closure is installed
    // here because it captures the view reference for the cached segment lookup.
    func makeUIView(context: Context) -> KiokuScrollingTextView {
        let view = KiokuScrollingTextView()
        view.alwaysBounceVertical = isScrollEnabled
        view.isScrollEnabled = isScrollEnabled
        // Cache the per-tap segment ranges on the view so updates and tap callbacks share
        // the same NSRange snapshot — converting Range<String.Index> on every tap is wasteful
        // and races with the text update.
        view.onCharacterTapped = { [weak view] characterIndex in
            guard let view else { return }
            guard let match = KiokuCoreTextSegmentResolver.segmentRange(
                forCharacterIndex: characterIndex,
                in: view.cachedSegmentNSRanges
            ) else {
                onSegmentTapped(nil, nil)
                return
            }
            let rect = view.contentView.layoutEngine.firstRect(forCharacterRange: match)
                .map { view.convertContentRectToHost($0) }
            onSegmentTapped(match.location, rect)
        }
        // Pinch → text-size binding. The coordinator captures the starting size on
        // .began so each .changed multiplies a stable base by the cumulative scale.
        let coordinator = context.coordinator
        view.onPinchBegan = { coordinator.pinchStartTextSize = textSize }
        view.onPinchChanged = { scale in
            let target = coordinator.pinchStartTextSize * Double(scale)
            let clamped = min(
                max(target, TypographySettings.textSizeRange.lowerBound),
                TypographySettings.textSizeRange.upperBound
            )
            textSize = clamped
        }
        return view
    }

    // Rebuilds the attributed string, applies layout (with per-line origin shifts for
    // wide-ruby line-starts), feeds the debug overlay, and emits inset / segment-gap
    // measurement logs when the inset-guide debug flag is on.
    func updateUIView(_ uiView: KiokuScrollingTextView, context: Context) {
        // Re-apply scroll enablement on every update so the LyricsView toggle is honored
        // when the host re-evaluates with a different value (e.g. dismiss vs. active).
        uiView.isScrollEnabled = isScrollEnabled
        uiView.alwaysBounceVertical = isScrollEnabled
        NSLog("[kioku.ct] updateUIView text.count=%d segments=%d furi=%d", text.count, segmentationRanges.count, furiganaBySegmentLocation.count)
        let font = UIFont.systemFont(ofSize: textSize)
        let attributed = KiokuCoreTextAttributedStringBuilder.build(
            .init(
                text: text,
                segmentationRanges: segmentationRanges,
                furiganaBySegmentLocation: furiganaBySegmentLocation,
                furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                textSize: textSize,
                lineSpacing: lineSpacing,
                kerning: kerning,
                isVisualEnhancementsEnabled: isVisualEnhancementsEnabled,
                isColorAlternationEnabled: isColorAlternationEnabled,
                isFuriganaVisible: isFuriganaVisible,
                isLineWrappingEnabled: isLineWrappingEnabled,
                isRubySpacingEnabled: isRubySpacingEnabled,
                evenSegmentColor: evenSegmentColor,
                oddSegmentColor: oddSegmentColor,
                unknownSegmentLocations: unknownSegmentLocations,
                isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                unknownSegmentColor: unknownSegmentColor
            )
        )
        uiView.contentView.setAttributedString(attributed)
        // CTRubyAnnotation already inflates the line's ascent to include the ruby row, so
        // we only add the user-configured extra spacing here — adding more would double-
        // reserve space above each line and visibly stretch the layout vs. TK2.
        uiView.contentView.setLineSpacing(lineSpacing)
        // Match TK2's UITextView.textContainerInset so layout origin and margins agree
        // between renderers (8pt top/bottom, 4pt left/right, lineFragmentPadding = 0).
        uiView.contentView.setContentInset(UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4))
        uiView.cachedSegmentNSRanges = segmentationRanges
            .map { NSRange($0, in: text) }
            .filter { $0.location != NSNotFound && $0.length > 0 }

        // Apply per-line origin shifts for wide-ruby line-starts. Replacement for TextKit
        // 2's textContainer.exclusionPaths. CTLineGetImageBounds doesn't include ruby
        // annotation extents (CT keeps ruby within the base run's advance with
        // overhang=.auto), so we compute the shift from the measured ruby vs. kanji
        // widths directly — same approach as TK2's exclusion-path width calculation.
        // Both shift sources are gated on isRubySpacingEnabled — when the user has Ruby
        // Spacing off, line origins stay flush at the inset, and ruby annotations are
        // allowed to overhang past the inset guide (matching TK2's behavior with the
        // same toggle off).
        var shifts: [Int: CGFloat] = [:]
        if isFuriganaVisible && isRubySpacingEnabled && furiganaBySegmentLocation.isEmpty == false {
            let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
            let widthShifts = KiokuWideRubyLineInset.shifts(
                for: .init(
                    lineStringStarts: uiView.contentView.layoutEngine.lines.map { $0.stringRange.location },
                    segmentNSRanges: uiView.cachedSegmentNSRanges,
                    readingByLocation: furiganaBySegmentLocation,
                    baseFont: font,
                    furiganaFont: furiganaFont,
                    kanjiWidthOverrides: [:]
                ),
                sourceText: text
            )
            for (k, v) in widthShifts { shifts[k] = max(shifts[k] ?? 0, v) }
            for (index, line) in uiView.contentView.layoutEngine.lines.enumerated() {
                let bounds = CTLineGetImageBounds(line.line, nil)
                if bounds.minX < 0 {
                    shifts[index] = max(shifts[index] ?? 0, ceil(-bounds.minX))
                }
            }
        }
        uiView.contentView.setLineOriginShifts(shifts)

        // Emit gap measurements to the unified log so the live app proves alignment
        // numerically — inset → first-segment-left per line, and segment-right → next-
        // segment-left per same-line pair. Toggled by the same flag as the visual
        // inset guide so it doesn't spam logs in normal use.
        // Dump segment-by-segment envelope heights so we can verify the standardization
        // is actually taking effect. Gated by envelopeRects toggle.
        if debugFlags.envelopeRects {
            for seg in uiView.debugOverlay.segmentGeometry.prefix(8) {
                NSLog("[kioku.ct.geom] loc=%d envelope=(%.1f,%.1f,%.1f,%.1f) headword.h=%.1f furi.h=%.1f",
                      seg.location,
                      Double(seg.envelopeRect.origin.x), Double(seg.envelopeRect.origin.y),
                      Double(seg.envelopeRect.width), Double(seg.envelopeRect.height),
                      Double(seg.headwordRect.height),
                      Double(seg.furiganaRect?.height ?? 0))
            }
        }
        // Mirror TK2's `[envelope-gap]` log so we can compare gaps side-by-side. Gated
        // by the same debug toggle TK2 uses (envelopeRects), so the two emit in lockstep.
        if debugFlags.envelopeRects {
            let nsText = text as NSString
            let ranges = uiView.cachedSegmentNSRanges
            for i in 0..<max(0, ranges.count - 1) {
                let a = ranges[i]
                let b = ranges[i + 1]
                guard let rectA = uiView.contentView.layoutEngine.firstRect(forCharacterRange: a),
                      let rectB = uiView.contentView.layoutEngine.firstRect(forCharacterRange: b) else { continue }
                guard abs(rectA.midY - rectB.midY) < 1.0 else { continue }
                let gap = rectB.minX - rectA.maxX
                guard abs(gap) >= 0.05 else { continue }
                NSLog("[kioku.ct envelope-gap] %@ → %@ gap=%.1fpt", nsText.substring(with: a), nsText.substring(with: b), Double(gap))
            }
        }
        if debugFlags.leftInsetGuide {
            let inset = uiView.contentView.layoutEngine.contentInset.left
            for (lineIndex, line) in uiView.contentView.layoutEngine.lines.enumerated() {
                guard let firstSeg = uiView.cachedSegmentNSRanges.first(where: { $0.location == line.stringRange.location }),
                      let rect = uiView.contentView.layoutEngine.firstRect(forCharacterRange: firstSeg)
                else { continue }
                let gap = rect.minX - inset
                NSLog("[kioku.ct.gap] line=\(lineIndex) inset=\(inset) firstSegLeft=\(rect.minX) gap=\(String(format: "%.2f", gap)) shift=\(shifts[lineIndex] ?? 0)")
            }
            // Inter-segment gaps, same-line pairs only. We measure from segment-A's
            // GLYPH right edge (excluding the trailing .kern we injected) to segment-B's
            // left edge. firstRect.maxX would include the kern advance and falsely
            // report gap=0, since adjacent segments share an edge in CTLine coords.
            let ranges = uiView.cachedSegmentNSRanges
            let nsText = text as NSString
            for i in 0..<max(0, ranges.count - 1) {
                let a = ranges[i]
                let b = ranges[i + 1]
                guard let rectA = uiView.contentView.layoutEngine.firstRect(forCharacterRange: a),
                      let rectB = uiView.contentView.layoutEngine.firstRect(forCharacterRange: b)
                else { continue }
                guard abs(rectA.midY - rectB.midY) < 5 else { continue }
                let surfaceA = nsText.substring(with: a)
                let glyphWidthA = ceil((surfaceA as NSString).size(withAttributes: [.font: font]).width)
                let glyphRightA = rectA.minX + glyphWidthA
                let gap = rectB.minX - glyphRightA
                NSLog("[kioku.ct.gap] pair locA=\(a.location) locB=\(b.location) surfaceA=\"\(surfaceA)\" glyphRightA=\(String(format: "%.2f", glyphRightA)) leftB=\(String(format: "%.2f", rectB.minX)) gap=\(String(format: "%.2f", gap))")
            }
        }

        // Feed the debug overlay. Computing geometry here (not in the overlay view's
        // draw pass) so the overlay can stay a pure renderer of pre-computed rects —
        // makes it easy to unit test and cheap to redraw on flag toggles.
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        let engineLines = uiView.contentView.layoutEngine.lines
        let nsText = text as NSString
        let baseFont = UIFont.systemFont(ofSize: textSize)

        // Segment rects span the FULL typographic advance from CTLine (no glyph-width
        // clipping). That way adjacent segments' envelopes touch edge-to-edge — the
        // trailing kern that pushes the next segment away stays INSIDE the current
        // segment's envelope, not as empty space between two envelopes.
        var firstRectByRange: [NSRange: CGRect] = [:]
        for range in uiView.cachedSegmentNSRanges {
            guard let r = uiView.contentView.layoutEngine.firstRect(forCharacterRange: range) else { continue }
            firstRectByRange[range] = r
        }

        // Tight kanji-run rects, one per ruby entry. Drives headword + bisector.
        var kanjiRunRectByLocation: [Int: CGRect] = [:]
        for (kanjiLoc, _) in furiganaBySegmentLocation {
            guard let kLen = furiganaLengthBySegmentLocation[kanjiLoc], kLen > 0 else { continue }
            let kRange = NSRange(location: kanjiLoc, length: kLen)
            guard let r = uiView.contentView.layoutEngine.firstRect(forCharacterRange: kRange) else { continue }
            let kanjiSurface = nsText.substring(with: kRange)
            let glyphWidth = ceil((kanjiSurface as NSString).size(withAttributes: [.font: baseFont]).width)
            kanjiRunRectByLocation[kanjiLoc] = CGRect(x: r.origin.x, y: r.origin.y, width: min(r.width, glyphWidth), height: r.height)
        }

        let geometryInputs = KiokuDebugOverlayGeometry.Inputs(
            firstRectByNSRange: firstRectByRange,
            segmentNSRanges: uiView.cachedSegmentNSRanges,
            kanjiRunRectByLocation: kanjiRunRectByLocation,
            kanjiRunLengthByLocation: furiganaLengthBySegmentLocation,
            readingByLocation: furiganaBySegmentLocation,
            baseFont: baseFont,
            furiganaFont: furiganaFont,
            lineFrames: engineLines.map { $0.frame },
            furiganaBandHeight: ceil(furiganaFont.lineHeight)
        )
        uiView.debugOverlay.segmentGeometry = KiokuDebugOverlayGeometry.segments(geometryInputs)
        uiView.debugOverlay.lineGeometry = KiokuDebugOverlayGeometry.lines(geometryInputs)
        uiView.debugOverlay.leftInsetX = uiView.contentView.layoutEngine.contentInset.left
        uiView.debugOverlay.illegalMergeLocation = illegalMergeLocation
        uiView.debugOverlay.flags = debugFlags

        // Selection sits below playback so a playing-tapped segment shows the playback color.
        var bands: [KiokuCoreTextView.HighlightBand] = []
        if let range = selectedHighlightRange, range.length > 0 {
            bands.append(.init(range: range, color: selectionHighlightColor))
        }
        if let range = playbackHighlightRange, range.length > 0 {
            bands.append(.init(range: range, color: playbackHighlightColor))
        }
        uiView.contentView.highlightBands = bands

        // Auto-scroll the playback range into view so the active cue stays visible during
        // audio playback. Targets ~32% from the top of the viewport to mirror the TK2 path.
        if let range = playbackHighlightRange, range.length > 0 {
            uiView.scrollRangeIntoView(range, anchorFraction: 0.32)
        }

        uiView.setNeedsLayout()
    }
}

// UIScrollView host for the CoreText content view. Owns layout passing — the content
// view's intrinsicContentSize is height-only, so we drive width from the scroll view's
// bounds and read height back to set contentSize.
final class KiokuScrollingTextView: UIScrollView {

    let contentView = KiokuCoreTextView()
    // Dev-only debug overlay sibling. Lives at the same coordinate origin as the
    // text content view so all rect math uses one space (no conversions). Hidden
    // when no flags are set so it's a no-op for normal users.
    let debugOverlay = KiokuDebugOverlayView()

    // Segment NSRanges snapshot — kept in sync with the most recent attributed string by
    // KiokuCoreTextRendererView.updateUIView so tap-handling can stay O(segments) without
    // re-bridging Swift Range<String.Index> on every tap.
    var cachedSegmentNSRanges: [NSRange] = []

    // Forwarded from the content view's tap recognizer. UTF-16 character index of the tap.
    var onCharacterTapped: ((Int) -> Void)? {
        didSet { wireContentTap() }
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

    // Sizes the content view to fill the width and grow to natural height; overlay tracks
    // the same frame so its rect math stays aligned with the engine output.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = contentView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        debugOverlay.frame = contentView.frame
        contentSize = CGSize(width: width, height: height)
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
}
