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

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

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

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if size.width > 0 {
            layoutEngine.setWidthConstraint(size.width)
        }
        return CGSize(width: size.width, height: layoutEngine.contentSize.height)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

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

    // MARK: - Tap handling

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

    override func accessibilityElementCount() -> Int {
        rebuildAccessibilityElementsIfNeeded().count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        let elements = rebuildAccessibilityElementsIfNeeded()
        guard elements.indices.contains(index) else { return nil }
        return elements[index]
    }

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
