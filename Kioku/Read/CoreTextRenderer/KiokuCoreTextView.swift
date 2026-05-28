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
    // under tap points. The Int? is nil when the tap lands in empty space (past a line's
    // content, in margins, below the last line) — that's how callers tell "tapped a
    // character" from "tapped nothing" so they can clear selection on the latter. A nil
    // closure means no tap recognizer is attached at all.
    var onTap: ((Int?, CGPoint) -> Void)? {
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

    // Per-kanji-run ruby (furigana) to draw above the base text. Each entry is the kanji
    // range in UTF-16 and the reading string to render centered above that range. The view
    // draws ruby manually in `draw(_:)` — CoreText's CTRubyAnnotation is intentionally not
    // used here because it gives no public knob for the kanji↔ruby gap. See the builder
    // header for the full rationale.
    var rubyEntries: [KiokuCoreTextAttributedStringBuilder.RubyEntry] = [] {
        didSet { setNeedsDisplay() }
    }

    // Vertical pixel offset between the top of the kanji's line box and the ruby's BASELINE.
    // Larger values push ruby further up. The space for ruby is reserved by the layout
    // engine's `topRubyReserve`; this property only controls where inside that reserve the
    // glyphs land.
    var furiganaGap: CGFloat = 0 {
        didSet { setNeedsDisplay() }
    }

    // Base text point size. Used to derive the ruby font (half-size, system) at draw time.
    // Set by the host alongside `setAttributedString`.
    var baseTextSize: CGFloat = UIFont.systemFontSize {
        didSet { setNeedsDisplay() }
    }

    // When set, overrides the implicit `baseTextSize * 0.5` furigana font size used by
    // `drawRuby`. nil (default) preserves the legacy ratio. The renderer host writes
    // through to this whenever the user's "Custom Furigana Size" toggle is on.
    var furiganaFontSizeOverride: CGFloat? = nil {
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

    // Sets extra inter-line padding. The host now passes ONLY the user-configured line
    // spacing here — room for ruby is reserved separately via `setTopRubyReserve`.
    func setLineSpacing(_ value: CGFloat) {
        layoutEngine.setLineSpacing(value)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    // Sets the per-line space above each line reserved for manually drawn ruby. Pass
    // `furiganaFont.lineHeight + furiganaGap` to match what TK2's top inset used to give.
    func setTopRubyReserve(_ value: CGFloat) {
        layoutEngine.setTopRubyReserve(value)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    // Passes segment NSRanges to the engine so it can forbid line breaks mid-segment. The
    // host should call this every time segments change so the layout reflows with atomic
    // segment wrapping. Empty array = no constraint.
    func setSegmentNSRanges(_ ranges: [NSRange]) {
        layoutEngine.setSegmentNSRanges(ranges)
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

        if layoutEngine.isSegmentPackingEnabled {
            // Per-segment draw: walk placements and render each segment's headword and
            // ruby at the X position the packer assigned. The base CTLine path is bypassed
            // because its X positions are CT's natural advance, not the packer's
            // footprint placement.
            drawSegmentPacked(in: context, dirtyRect: rect)
        } else {
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

            // Ruby pass: walk entries and draw each reading centered over its kanji rect, with
            // its baseline `furiganaGap` pixels above the kanji's line-box top. Done after the
            // base text so ruby paints on top of any glyphs it touches (it shouldn't, but the
            // ordering keeps that safe). Still inside the flipped (CT bottom-up) coord space.
            drawRuby(in: context, dirtyRect: rect)
        }

        context.restoreGState()
    }

    // Per-segment renderer used when the engine is in segment-packed mode. For each
    // placement, draws (1) the segment's headword CTLine at its centered X within the
    // footprint, and (2) the segment's ruby CTLine centered above the headword. Adjacent
    // placements have zero gap between footprints by construction (the packer placed
    // them that way), so visually segments touch and ruby never crosses footprint edges.
    private func drawSegmentPacked(in context: CGContext, dirtyRect: CGRect) {
        let baseFontSize = baseTextSize
        let furiganaFont = UIFont.systemFont(ofSize: max(1, furiganaFontSizeOverride ?? (baseFontSize * 0.5)))
        var rubyAscent: CGFloat = 0
        var rubyDescent: CGFloat = 0
        var rubyLeading: CGFloat = 0
        let probeRubyLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "あ", attributes: [.font: furiganaFont]) as CFAttributedString
        )
        _ = CGFloat(CTLineGetTypographicBounds(probeRubyLine, &rubyAscent, &rubyDescent, &rubyLeading))

        let dirtyInFlipped = CGRect(
            x: dirtyRect.minX,
            y: bounds.height - dirtyRect.maxY,
            width: dirtyRect.width,
            height: dirtyRect.height
        )
        let placementsByLine = Dictionary(grouping: layoutEngine.segmentPlacements, by: \.lineIndex)
        for line in layoutEngine.packedLines {
            // Cull off-screen lines.
            let lineFlipped = CGRect(
                x: 0,
                y: bounds.height - (line.originY + line.height),
                width: bounds.width,
                height: line.height
            )
            guard lineFlipped.intersects(dirtyInFlipped) else { continue }
            let baselineY = line.originY + line.ascent
            let baselineYBottomUp = bounds.height - baselineY
            // Honor the renderer's centering shift on this line — the packer assigns
            // placement.originX assuming the line starts at leftInset, but the line may have
            // been shifted (centered/right-aligned) post-layout via lineOriginShifts. Without
            // adding the shift here, packed glyphs ignore centering even when CTLine-drawn
            // text wouldn't.
            let lineShift = layoutEngine.lineOriginShifts[line.lineIndex] ?? 0
            for placement in placementsByLine[line.lineIndex] ?? [] {
                let segNSRange = NSRange(location: placement.location, length: placement.length)
                let segAttr = layoutEngine.attributedString.attributedSubstring(from: segNSRange)
                let segLine = CTLineCreateWithAttributedString(segAttr as CFAttributedString)
                let headwordOriginX = placement.originX + placement.leftOverhang + lineShift
                context.textPosition = CGPoint(x: headwordOriginX, y: baselineYBottomUp)
                CTLineDraw(segLine, context)
            }
        }

        // Per-segment ruby pass. We use the per-segment placements directly rather than
        // the rubyEntries list so positioning matches the packer's geometry exactly.
        guard rubyEntries.isEmpty == false else { return }
        let rubyByLocation = Dictionary(uniqueKeysWithValues: rubyEntries.map { ($0.location, $0) })
        for line in layoutEngine.packedLines {
            let lineFlipped = CGRect(
                x: 0,
                y: bounds.height - (line.originY + line.height),
                width: bounds.width,
                height: line.height
            )
            guard lineFlipped.intersects(dirtyInFlipped) else { continue }
            // Same per-line centering shift the headword pass applied above — ruby has to
            // ride along, otherwise furigana floats independently of its kanji when the
            // active card is centered.
            let rubyLineShift = layoutEngine.lineOriginShifts[line.lineIndex] ?? 0
            for placement in placementsByLine[line.lineIndex] ?? [] {
                // Ruby entries may live at a kanji-run location inside the segment, not at
                // the segment's start. Iterate every ruby entry whose location falls in
                // the segment range and draw each centered over its kanji-run rect.
                for kanjiLoc in rubyByLocation.keys
                where kanjiLoc >= placement.location && kanjiLoc < placement.location + placement.length {
                    guard let entry = rubyByLocation[kanjiLoc] else { continue }
                    // Compute kanji-run X within the segment by measuring its position in
                    // the segment's CTLine. Segment-local indices into the headword.
                    let segNSRange = NSRange(location: placement.location, length: placement.length)
                    let segAttr = layoutEngine.attributedString.attributedSubstring(from: segNSRange)
                    let segLine = CTLineCreateWithAttributedString(segAttr as CFAttributedString)
                    let localStart = entry.location - placement.location
                    let localEnd = localStart + entry.length
                    let xStart = CTLineGetOffsetForStringIndex(segLine, localStart, nil)
                    let xEnd = CTLineGetOffsetForStringIndex(segLine, localEnd, nil)
                    let headwordOriginX = placement.originX + placement.leftOverhang + rubyLineShift
                    let kanjiMidXInHeadword = (xStart + xEnd) / 2
                    let kanjiMidX = headwordOriginX + kanjiMidXInHeadword
                    let rubyAttr = NSAttributedString(
                        string: entry.reading,
                        attributes: [.font: furiganaFont, .foregroundColor: rubyForegroundColor(at: entry.location)]
                    )
                    let rubyLine = CTLineCreateWithAttributedString(rubyAttr as CFAttributedString)
                    var ra: CGFloat = 0
                    var rd: CGFloat = 0
                    var rl: CGFloat = 0
                    let rubyWidth = CGFloat(CTLineGetTypographicBounds(rubyLine, &ra, &rd, &rl))
                    let rubyOriginX = kanjiMidX - rubyWidth / 2
                    // Place ruby's bottom `furiganaGap` above the kanji's visual top.
                    // kanji visual top ≈ line.originY (line box top in Japanese-dominant lines).
                    let rubyBaselineTopDown = line.originY - furiganaGap - rd
                    let rubyBaselineBottomUp = bounds.height - rubyBaselineTopDown
                    context.textPosition = CGPoint(x: rubyOriginX, y: rubyBaselineBottomUp)
                    CTLineDraw(rubyLine, context)
                }
            }
        }
    }

    // Reads the foreground color from the attributed string at the given location, falling
    // back to .label. Mirrors the lookup used by the classic-mode drawRuby pass.
    private func rubyForegroundColor(at location: Int) -> UIColor {
        let attrs = layoutEngine.attributedString.attributes(at: location, effectiveRange: nil)
        return (attrs[.foregroundColor] as? UIColor) ?? .label
    }

    // Builds a CTLine for each ruby entry and draws it above the corresponding kanji rect.
    // Splits ruby positioning into two pieces, matching what TextKit-era code did:
    //   - reserve = furiganaFont.lineHeight + furiganaGap  (carried by engine.topRubyReserve)
    //   - placement = `kanjiRect.minY - furiganaGap - rubyAscent` (UIKit top-down)
    // The reserve is set by the host; the placement is what the slider tunes.
    private func drawRuby(in context: CGContext, dirtyRect: CGRect) {
        guard rubyEntries.isEmpty == false else { return }
        let furiganaFont = UIFont.systemFont(ofSize: max(1, furiganaFontSizeOverride ?? (baseTextSize * 0.5)))
        let ctFuriganaFont = furiganaFont as CTFont
        let nsString = layoutEngine.attributedString.string as NSString

        // Dirty rect in flipped (CT bottom-up) space so we can cull cheaply.
        let dirtyInFlipped = CGRect(
            x: dirtyRect.minX,
            y: bounds.height - dirtyRect.maxY,
            width: dirtyRect.width,
            height: dirtyRect.height
        )

        for entry in rubyEntries {
            let range = NSRange(location: entry.location, length: entry.length)
            guard range.location >= 0, range.length > 0,
                  range.location + range.length <= nsString.length else { continue }
            guard let kanjiRect = layoutEngine.firstRect(forCharacterRange: range) else { continue }

            // Foreground color: read the kanji's foregroundColor attribute so the ruby
            // matches its kanji's segment-alternation color. Falls back to `.label`.
            let fgColor: UIColor = {
                let attrs = layoutEngine.attributedString.attributes(at: range.location, effectiveRange: nil)
                if let color = attrs[.foregroundColor] as? UIColor { return color }
                return .label
            }()

            // Build the ruby line. Attributes mirror the base build except sized to the ruby
            // font; no paragraph style needed for a single-line CTLine.
            let rubyAttributed = NSAttributedString(
                string: entry.reading,
                attributes: [
                    .font: furiganaFont,
                    .foregroundColor: fgColor,
                ]
            )
            let rubyLine = CTLineCreateWithAttributedString(rubyAttributed)
            var rubyAscent: CGFloat = 0
            var rubyDescent: CGFloat = 0
            var rubyLeading: CGFloat = 0
            let rubyWidth = CGFloat(CTLineGetTypographicBounds(rubyLine, &rubyAscent, &rubyDescent, &rubyLeading))
            _ = ctFuriganaFont  // suppress unused-binding warning; kept for potential future per-glyph work

            // Center the ruby horizontally over the kanji rect. When ruby is wider than its
            // kanji, the inter-segment kern compensation in the builder has already pushed
            // the neighbors away to make room.
            let x = kanjiRect.midX - rubyWidth / 2
            // "furiganaGap" = pixels between the ruby's VISIBLE BOTTOM and the kanji's
            // VISIBLE TOP — that's what a user means when they reach for the slider. Solve
            // for the ruby baseline:
            //   rubyVisibleBottom = baseline + rubyDescent
            //   kanjiVisibleTop   ≈ kanjiRect.minY      (Japanese-dominant lines)
            //   gap = kanjiVisibleTop - rubyVisibleBottom = furiganaGap
            //   → baseline = kanjiRect.minY - furiganaGap - rubyDescent
            //
            // Prior version subtracted rubyAscent here, which placed the ruby's TOP (not
            // bottom) `furiganaGap` above the kanji — visually offset by ~rubyAscent + the
            // gap, i.e. way too far up. With default gap=2 the visible regression was a
            // ~7pt jump, matching the reported "way too much space" symptom.
            let baselineTopDown = kanjiRect.minY - furiganaGap - rubyDescent
            let baselineBottomUp = bounds.height - baselineTopDown

            // Coarse dirty-rect cull on the ruby's typographic box.
            let rubyBox = CGRect(
                x: x,
                y: baselineBottomUp - rubyAscent,
                width: rubyWidth,
                height: rubyAscent + rubyDescent
            )
            guard rubyBox.intersects(dirtyInFlipped) else { continue }

            context.textPosition = CGPoint(x: x, y: baselineBottomUp)
            CTLineDraw(rubyLine, context)
        }
    }

    // MARK: - Highlight bands

    // Paints each band's union-of-line rects with rounded corners. Skips bands fully outside
    // the dirty rect for cheap partial redraws.
    private func drawHighlightBands(in context: CGContext, dirtyRect: CGRect) {
        guard highlightBands.isEmpty == false else { return }
        // Extend each band's top edge up over the ruby annotation zone so furigana above a
        // highlighted kanji also sits on the band. Without this the band stops below the
        // kanji's line box and the ruby floats unbanded above. Only applies when furigana
        // is actually being drawn (rubyEntries non-empty) so plain-text highlights stay
        // flush with the line.
        let rubyExtraTop: CGFloat = rubyEntries.isEmpty
            ? 0
            : ((furiganaFontSizeOverride ?? (baseTextSize * 0.5)) + max(0, furiganaGap))
        for band in highlightBands {
            guard band.range.location != NSNotFound, band.range.length > 0 else { continue }
            let rects = layoutEngine.boundingRects(forCharacterRange: band.range)
            for rect in rects {
                let inset = rect.insetBy(dx: 0, dy: band.verticalInset)
                let padded = CGRect(
                    x: inset.minX,
                    y: inset.minY - rubyExtraTop,
                    width: inset.width,
                    height: inset.height + rubyExtraTop
                )
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
    // UTF-16 character index to the host. Forwards `nil` for empty-space taps so the
    // host can clear selection instead of pinning to the nearest character.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        TapDiagnostics.beginTap()
        let point = recognizer.location(in: self)
        let index = layoutEngine.characterIndex(at: point)
        TapDiagnostics.mark("layoutEngine.characterIndex returned (index=\(index.map(String.init) ?? "nil"))")
        onTap?(index, point)
        TapDiagnostics.mark("onTap callback returned (KiokuCoreTextView.handleTap)")
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
