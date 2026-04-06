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
    // Per-character-index colors within `surface` (UTF-16 offsets local to this view's surface string).
    // When non-empty, overrides textColor for each run.
    private var segmentColors: [Int: UIColor] = [:]
    // Explicit per-run readings keyed by the run's start character index in `surface`.
    // When provided, used directly instead of projecting from the full `reading` string.
    private var explicitRunReadings: [Int: String] = [:]

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
    // segmentColors: per-UTF-16-offset colors local to `surface` (not the full note text).
    // explicitRunReadings: per-kanji-run readings keyed by run start character index in surface.
    //   When provided, bypasses projectRunReadings so every kanji run gets its reading directly.
    func configure(
        surface: String,
        reading: String,
        font: UIFont,
        gap: CGFloat,
        textColor: UIColor = .label,
        segmentColors: [Int: UIColor] = [:],
        explicitRunReadings: [Int: String] = [:]
    ) {
        self.surface = surface
        self.reading = reading
        self.font = font
        self.gap = gap
        self.plainText = surface
        self.textColor = textColor
        self.segmentColors = segmentColors
        self.explicitRunReadings = explicitRunReadings
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
        // Prefer contextual screen width; fall back to trait/environment if needed.
        let contextualScreenWidth: CGFloat = (
            window?.windowScene?.screen.bounds.width
        ) ?? (
            // If no window yet (e.g., during offscreen layout), try the superview or view's bounds.
            superview?.bounds.width
        ) ?? (
            // As a last resort, use the view's own bounds width.
            bounds.width
        )
        let width = size.width > 0 ? size.width : contextualScreenWidth
        return CGSize(width: width, height: computeHeight(for: width))
    }

    override func draw(_ rect: CGRect) {
        let baseAttrString = baseAttributedString()
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * 0.5)
        let topInset = furiganaFont.lineHeight + gap

        let drawWidth = bounds.width > 0 ? bounds.width : rect.width
        // The base text sits below the furigana headroom, drawn in UIKit coordinates.
        let textRect = CGRect(x: 0, y: topInset, width: drawWidth, height: rect.height - topInset)

        // Draw base text using UIKit — no coordinate flip needed.
        baseAttrString.draw(in: textRect)

        // Locate each kanji run, then resolve per-run readings.
        // Prefer explicitRunReadings (keyed by run start char index) when provided — they come directly from furiganaBySegmentLocation and are always correct per segment.
        // Fall back to normalizedRunReadings which projects from the concatenated full reading.
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard !runs.isEmpty else { return }

        let runReadings: [String]
        if explicitRunReadings.isEmpty == false {
            runReadings = runs.map { explicitRunReadings[$0.start] ?? "" }
        } else if let projected = FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: reading, runs: runs),
                  projected.count == runs.count {
            runReadings = projected
        } else {
            return
        }

        let runRects = uikitRunRects(for: baseAttrString, runs: runs, in: textRect)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        for (i, runReading) in runReadings.enumerated() {
            guard !runReading.isEmpty, i < runRects.count else { continue }
            let runRect = runRects[i]
            guard runRect != .null else { continue }

            let runColor = segmentColors[runs[i].start] ?? textColor
            let furiganaAttributes: [NSAttributedString.Key: Any] = [
                .font: furiganaFont,
                .foregroundColor: runColor,
                .paragraphStyle: paragraphStyle,
            ]

            let furiganaSize = (runReading as NSString).size(withAttributes: furiganaAttributes)
            let furiganaX = runRect.midX - furiganaSize.width / 2
            // Place furigana above the run rect with the configured gap.
            let furiganaY = runRect.minY - gap - furiganaSize.height
            (runReading as NSString).draw(
                in: CGRect(x: furiganaX, y: furiganaY, width: furiganaSize.width, height: furiganaSize.height),
                withAttributes: furiganaAttributes
            )
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

    // Computes the natural (unconstrained) size of the label — the width the text occupies
    // on a single line, and the corresponding height. Used when InlineWrapLayout asks for
    // a chip's size with no width constraint (.unspecified proposal).
    func naturalSize() -> CGSize {
        let attrString = baseAttributedString()
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * 0.5)
        // Also account for the furigana text width, which may be wider than the kanji surface.
        let furiganaWidth = (reading as NSString).size(
            withAttributes: [.font: furiganaFont]
        ).width
        let naturalWidth = ceil(max(size.width, furiganaWidth))
        let naturalHeight = ceil(size.height) + furiganaFont.lineHeight + gap
        return CGSize(width: naturalWidth, height: naturalHeight)
    }

    // Builds a plain attributed string (no ruby) for CoreText base-text layout.
    // Applies per-character segment colors when segmentColors is populated.
    private func baseAttributedString() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrString = NSMutableAttributedString(string: surface, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ])
        // Apply per-segment colors. Walk UTF-16 units; batch contiguous offsets with the
        // same color into a single NSRange attribute call.
        if segmentColors.isEmpty == false {
            let count = surface.utf16.count
            var offset = 0
            while offset < count {
                guard let color = segmentColors[offset] else { offset += 1; continue }
                // Find how far this exact color extends without interruption.
                var end = offset + 1
                while end < count, let next = segmentColors[end], next.isEqual(color) { end += 1 }
                attrString.addAttribute(.foregroundColor, value: color, range: NSRange(location: offset, length: end - offset))
                offset = end
            }
        }
        return attrString
    }

    // Returns the UIKit-coordinate bounding rect for each kanji run within the laid-out text rect.
    // Uses NSLayoutManager to measure glyph positions — same coordinate space as NSAttributedString.draw(in:).
    private func uikitRunRects(for attrString: NSAttributedString, runs: [(start: Int, end: Int)], in textRect: CGRect) -> [CGRect] {
        guard !runs.isEmpty else { return [] }

        let storage = NSTextStorage(attributedString: attrString)
        let container = NSTextContainer(size: textRect.size)
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        return runs.map { run in
            // Union the glyph rects for every character in this run.
            var unionRect = CGRect.null
            for charIndex in run.start..<run.end {
                let glyphRange = manager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
                manager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { glyphRect, _ in
                    // glyphRect is in the text container's coordinate space; offset by textRect origin.
                    let viewRect = glyphRect.offsetBy(dx: textRect.minX, dy: textRect.minY)
                    unionRect = unionRect.union(viewRect)
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
