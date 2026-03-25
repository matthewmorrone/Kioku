import UIKit
import CoreText

// UIView subclass that renders Japanese text with per-kanji-run furigana drawn manually above each kanji run.
// Replaces CTRubyAnnotation with explicit overlay drawing so the gap between furigana and base text is controllable.
// Supports long-press copy via UIContextMenuInteraction.
final class FuriganaView: UIView, UIContextMenuInteractionDelegate {

    // The plain text to copy when the user long-presses.
    private(set) var plainText: String = ""

    // Called when the user taps the view. Set to enable tap handling.
    var onTap: (() -> Void)? {
        didSet { configureTapGesture() }
    }
    private var tapGesture: UITapGestureRecognizer?

    private var surface: String = ""
    private var reading: String = ""
    private var font: UIFont = .systemFont(ofSize: 18)
    // Vertical gap in points between the bottom of the furigana text and the top of the base glyph.
    private var gap: CGFloat = 2

    private var textColor: UIColor = .label

    // Intrinsic size is computed from CoreText layout at the last known width.
    private var lastLayoutWidth: CGFloat = 0

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
        isUserInteractionEnabled = true
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    // Installs or removes the tap gesture recognizer based on whether onTap is set.
    private func configureTapGesture() {
        if let existing = tapGesture {
            removeGestureRecognizer(existing)
            tapGesture = nil
        }
        guard onTap != nil else { return }
        let gr = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(gr)
        tapGesture = gr
    }

    @objc private func handleTap() {
        onTap?()
    }

    // Sets the text content and visual parameters. Triggers relayout and redraw.
    func configure(surface: String, reading: String, font: UIFont, gap: CGFloat, textColor: UIColor = .label) {
        self.surface = surface
        self.reading = reading
        self.font = font
        self.gap = gap
        self.plainText = surface
        self.textColor = textColor
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        let width = lastLayoutWidth > 0 ? lastLayoutWidth : superview?.bounds.width ?? window?.screen.bounds.width ?? 390
        let height = computeHeight(for: width)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Recompute intrinsic height when width changes so the sheet detent resizes.
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    // Returns the natural size for the given bounding size, used by UIViewRepresentable.sizeThatFits.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width > 0 ? size.width : UIScreen.main.bounds.width
        return CGSize(width: width, height: computeHeight(for: width))
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let baseAttrString = baseAttributedString()
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * 0.5)
        // Reserve headroom at the top so the first line's furigana is never clipped.
        let topInset = furiganaFont.lineHeight + gap
        let textRect = CGRect(x: rect.minX, y: rect.minY + topInset, width: rect.width, height: rect.height - topInset)

        // Compute per-run readings for furigana placement.
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        let runReadings = FuriganaAttributedString.projectRunReadings(surface: surface, reading: reading, runs: runs)

        // Measure each run rect using CoreText within the inset text area.
        let runRects = rubyRunRects(for: baseAttrString, runs: runs, in: textRect)

        // Draw base text via CoreText into the inset rect (no ruby annotations).
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        let framesetter = CTFramesetterCreateWithAttributedString(baseAttrString)
        let framePath = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), framePath, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()

        // Draw furigana strings above each kanji run in UIKit coordinates.
        guard let runReadings, runReadings.count == runs.count else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        let furiganaAttributes: [NSAttributedString.Key: Any] = [
            .font: furiganaFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]

        for (i, runReading) in runReadings.enumerated() {
            guard !runReading.isEmpty, i < runRects.count else { continue }
            let runRect = runRects[i]
            guard runRect != .null else { continue }

            let furiganaSize = (runReading as NSString).size(withAttributes: furiganaAttributes)
            let furiganaX = runRect.midX - furiganaSize.width / 2
            // Position furigana so its bottom edge sits `gap` points above the top of the base glyph rect.
            let furiganaY = runRect.minY - gap - furiganaSize.height
            let furiganaRect = CGRect(x: furiganaX, y: furiganaY, width: furiganaSize.width, height: furiganaSize.height)

            (runReading as NSString).draw(in: furiganaRect, withAttributes: furiganaAttributes)
        }
    }

    // Computes the height needed to fit base text plus furigana headroom at the given width.
    private func computeHeight(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(baseAttributedString())
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * 0.5)
        // Reserve room for furigana text plus the gap above the first baseline.
        return ceil(size.height) + furiganaFont.lineHeight + gap
    }

    // Builds a plain attributed string (no ruby) for CoreText base-text layout.
    private func baseAttributedString() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: surface, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ])
    }

    // Returns the UIKit-coordinate bounding rect for each kanji run in the base text layout.
    // Uses CoreText glyph positions to compute per-run rects so furigana centers correctly.
    private func rubyRunRects(for attrString: NSAttributedString, runs: [(start: Int, end: Int)], in rect: CGRect) -> [CGRect] {
        guard !runs.isEmpty else { return [] }

        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let framePath = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), framePath, nil)

        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &lineOrigins)

        // Build a map from character index → glyph rect in UIKit coordinates (y flipped).
        var charRects: [Int: CGRect] = [:]
        let chars = Array(surface)

        for (lineIndex, line) in lines.enumerated() {
            let lineOrigin = lineOrigins[lineIndex]
            let lineRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []

            for run in lineRuns {
                let runAttrs = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
                _ = runAttrs // suppress unused warning

                let glyphCount = CTRunGetGlyphCount(run)
                let runRange = CTRunGetStringRange(run)

                for glyphIndex in 0..<glyphCount {
                    let glyphRange = CFRangeMake(glyphIndex, 1)
                    var glyphBounds = CGRect.zero
                    CTRunGetTypographicBounds(run, glyphRange, nil, nil, nil)
                    let xOffset = CTLineGetOffsetForStringIndex(line, runRange.location + glyphIndex, nil)

                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    CTRunGetTypographicBounds(run, glyphRange, &ascent, &descent, nil)

                    // CoreText origin is bottom-left of the frame rect; convert to UIKit top-left view coordinates.
                    // rect.minY offsets back into view space when the frame rect is inset from the view top.
                    let glyphX = lineOrigin.x + xOffset
                    let glyphY = rect.minY + rect.height - (lineOrigin.y + ascent)
                    let glyphH = ascent + descent

                    var glyphAdvance: CGFloat = 0
                    CTRunGetTypographicBounds(run, glyphRange, nil, nil, &glyphAdvance)
                    glyphBounds = CGRect(x: glyphX, y: glyphY, width: glyphAdvance, height: glyphH)

                    let charIndex = runRange.location + glyphIndex
                    if charIndex < chars.count {
                        charRects[charIndex] = glyphBounds
                    }
                }
            }
        }

        // Union glyph rects across each run to get a bounding rect per kanji run.
        return runs.map { run in
            var unionRect = CGRect.null
            for i in run.start..<run.end {
                if let r = charRects[i] {
                    unionRect = unionRect.union(r)
                }
            }
            return unionRect
        }
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard plainText.isEmpty == false else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = self?.plainText
            }
            return UIMenu(title: "", children: [copyAction])
        }
    }
}
