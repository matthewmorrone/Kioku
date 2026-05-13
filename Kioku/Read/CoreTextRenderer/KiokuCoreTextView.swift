import UIKit
import CoreText

// CoreText-backed UIView that renders the Read view's base text without TextKit 2. Designed
// to be a drop-in replacement for the UITextView currently used by FuriganaTextRenderer for
// the read-mode body, plus the overlay subview that draws ruby and selection envelopes.
//
// Scope of this layer:
//   - Owns a KiokuTextLayoutEngine.
//   - Reflows on bounds.width changes; redraws on attributed-string or width changes.
//   - Draws the base text (CTLineDraw); ruby + segment overlays are still rendered by a
//     sibling overlay view that consumes per-segment rects from this view.
//   - Exposes per-character-range rects and a tap → character-index helper that the
//     coordinator uses for segment hit testing.
//
// What is intentionally NOT here yet (deferred):
//   - Selection caret, drag-to-select, copy menu (Read view doesn't need editing).
//   - Accessibility line-by-line UIAccessibilityElement exposure.
//   - Scroll integration — this view is a content view; embed it in a UIScrollView.
//   - Ruby drawing — handled by a separate overlay file once integration begins.
final class KiokuCoreTextView: UIView {

    // The layout engine. Public only as read-only so other components can query rects/indices
    // without re-running layout themselves.
    private(set) var layoutEngine = KiokuTextLayoutEngine()

    // Tap handling: parent installs this closure to be notified of UTF-16 character indices
    // under tap points. Nil means no tap recognizer is attached.
    var onTap: ((Int, CGPoint) -> Void)? {
        didSet { configureTapGesture() }
    }
    private var tapGesture: UITapGestureRecognizer?

    // Highlight bands drawn under the text. The selection band sits below the playback band
    // so an actively-playing tapped segment shows the playback color on top. Ranges are
    // UTF-16 against the current attributed string.
    struct HighlightBand {
        var range: NSRange
        var color: UIColor
        // Padding around the typographic bounds. Use a small negative inset to bleed past
        // glyph extents the way TextKit 2's selection rect does, or positive to inset.
        var verticalInset: CGFloat = -2
        var cornerRadius: CGFloat = 4
    }

    // The order is significant — painted back-to-front, so the last entry overlays earlier
    // ones. Callers responsible for ordering selection vs. playback.
    var highlightBands: [HighlightBand] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    // Shared init for both `init(frame:)` and `init?(coder:)` so styling stays
    // consistent regardless of how the view is instantiated.
    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    // Sets the source attributed string. Triggers relayout + redraw only when the value differs.
    func setAttributedString(_ value: NSAttributedString) {
        layoutEngine.setAttributedString(value)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    // Sets the content inset (top/left/bottom/right padding inside the view). Useful for
    // matching UITextView.textContainerInset semantics.
    func setContentInset(_ value: UIEdgeInsets) {
        layoutEngine.setContentInset(value)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    // Sets extra inter-line padding. Pass the ruby font height when CTRubyAnnotation is in
    // play so consecutive lines don't overlap on the kanji row.
    func setLineSpacing(_ value: CGFloat) {
        layoutEngine.setLineSpacing(value)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    // Sets per-line X-origin shifts. Used by the wide-ruby line-start inset replacement.
    // Indices are 0-based against the engine's `lines`.
    func setLineOriginShifts(_ shifts: [Int: CGFloat]) {
        layoutEngine.setLineOriginShifts(shifts)
        setNeedsDisplay()
    }

    // Forwards bounds.width to the engine so the layout reflows on rotation / split-view.
    override func layoutSubviews() {
        super.layoutSubviews()
        let priorHeight = layoutEngine.contentSize.height
        layoutEngine.setWidthConstraint(bounds.width)
        if abs(layoutEngine.contentSize.height - priorHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(width: UIView.noIntrinsicMetric, height: layoutEngine.contentSize.height)
    }

    // Reports the height the engine would produce at the given width. Lets host scroll
    // views ask "how tall do you need to be" without a full relayout cycle.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if size.width > 0 {
            layoutEngine.setWidthConstraint(size.width)
        }
        return CGSize(width: size.width, height: layoutEngine.contentSize.height)
    }

    // Paints highlight bands first (in UIKit coords), then flips the context and draws each
    // CTLine. Clipping to dirty rect skips off-screen lines on partial redraws.
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Draw highlight bands BEFORE flipping into CT coordinates — bands live in UIKit
        // top-down space, which lets us use the engine's rects directly.
        drawHighlightBands(in: context, dirtyRect: rect)

        // Flip into CoreText's bottom-up coordinate space once at the view boundary so all
        // layout math elsewhere can stay in UIKit's top-down convention.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        for line in layoutEngine.lines {
            // Skip lines outside the dirty rect — cheap clipping for partial redraws.
            let flippedFrame = CGRect(
                x: line.origin.x,
                y: bounds.height - (line.origin.y + line.height),
                width: line.width,
                height: line.height
            )
            let dirtyInFlipped = CGRect(
                x: rect.minX,
                y: bounds.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            guard flippedFrame.intersects(dirtyInFlipped) else { continue }

            let baselineYBottomUp = bounds.height - line.baselineY
            context.textPosition = CGPoint(x: line.origin.x, y: baselineYBottomUp)
            CTLineDraw(line.line, context)
        }

        context.restoreGState()
    }

    // MARK: - Highlight bands

    // Paints each band's union-of-line rects with rounded corners. Skips bands fully outside
    // the dirty rect for cheap partial redraws.
    private func drawHighlightBands(in context: CGContext, dirtyRect: CGRect) {
        guard highlightBands.isEmpty == false else { return }
        for band in highlightBands {
            guard band.range.location != NSNotFound, band.range.length > 0 else { continue }
            let rects = layoutEngine.boundingRects(forCharacterRange: band.range)
            for rect in rects {
                let padded = rect.insetBy(dx: 0, dy: band.verticalInset)
                guard padded.intersects(dirtyRect) else { continue }
                let path = UIBezierPath(roundedRect: padded, cornerRadius: band.cornerRadius)
                context.setFillColor(band.color.cgColor)
                context.addPath(path.cgPath)
                context.fillPath()
            }
        }
    }

    // MARK: - Tap handling

    // Installs or removes the tap recognizer to match whether `onTap` is set.
    private func configureTapGesture() {
        if let existing = tapGesture {
            removeGestureRecognizer(existing)
            tapGesture = nil
        }
        guard onTap != nil else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(recognizer)
        tapGesture = recognizer
    }

    // Routes the tap location through the engine's hit-test and forwards the resulting
    // UTF-16 character index to the host via the `onTap` closure.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard let index = layoutEngine.characterIndex(at: point) else { return }
        onTap?(index, point)
    }

    // MARK: - Accessibility

    // Per-line UIAccessibilityElement exposure so VoiceOver and the rotor see meaningful
    // structure. Built lazily and rebuilt only when the layout actually changes — line count
    // and string-range fingerprint are the trigger.
    private var cachedAccessibilityElements: [UIAccessibilityElement] = []
    private var cachedAccessibilityFingerprint: Int = 0

    override var accessibilityElements: [Any]? {
        get { rebuildAccessibilityElementsIfNeeded() }
        set { /* read-only */ }
    }

    // Number of per-line accessibility elements VoiceOver should expose.
    override func accessibilityElementCount() -> Int {
        rebuildAccessibilityElementsIfNeeded().count
    }

    // Element at the given index (per-line, in document order). Nil when out of range.
    override func accessibilityElement(at index: Int) -> Any? {
        let elements = rebuildAccessibilityElementsIfNeeded()
        guard elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    // Reverse lookup: position of a given accessibility element in the per-line array.
    override func index(ofAccessibilityElement element: Any) -> Int {
        let elements = rebuildAccessibilityElementsIfNeeded()
        return elements.firstIndex(where: { $0 === (element as AnyObject) }) ?? NSNotFound
    }

    // Computes a cheap fingerprint of the current layout. Rebuilds elements only when this
    // changes, so VO traversals over a steady-state view don't pay relayout cost.
    private func rebuildAccessibilityElementsIfNeeded() -> [UIAccessibilityElement] {
        var hasher = Hasher()
        hasher.combine(layoutEngine.attributedString.string)
        hasher.combine(layoutEngine.lines.count)
        for line in layoutEngine.lines {
            hasher.combine(line.stringRange.location)
            hasher.combine(line.stringRange.length)
            hasher.combine(Int(line.origin.y * 100))
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != cachedAccessibilityFingerprint else {
            return cachedAccessibilityElements
        }
        cachedAccessibilityFingerprint = fingerprint
        cachedAccessibilityElements = makeAccessibilityElements()
        return cachedAccessibilityElements
    }

    // Builds one UIAccessibilityElement per non-empty laid-out line, anchored at the
    // line's frame in container space, with the line's text as the a11y label.
    private func makeAccessibilityElements() -> [UIAccessibilityElement] {
        let sourceText = layoutEngine.attributedString.string as NSString
        return layoutEngine.lines.compactMap { line -> UIAccessibilityElement? in
            guard line.stringRange.length > 0,
                  line.stringRange.location + line.stringRange.length <= sourceText.length else {
                return nil
            }
            let lineText = sourceText.substring(with: line.stringRange)
                .trimmingCharacters(in: .newlines)
            guard lineText.isEmpty == false else { return nil }
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = lineText
            element.accessibilityFrameInContainerSpace = line.frame
            element.accessibilityTraits = .staticText
            return element
        }
    }
}
