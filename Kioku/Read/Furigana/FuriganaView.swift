import UIKit
import CoreText

// UIView subclass that renders Japanese text with per-kanji-run furigana drawn manually above each kanji run.
// Replaces CTRubyAnnotation with explicit overlay drawing so the gap between furigana and base text is controllable.
// Supports long-press copy via UIContextMenuInteraction.
// Avoids furigana clipping the same way KiokuCoreTextAttributedStringBuilder does for paragraph
// text: when a run's ruby is wider than the run itself, kern its neighbor away to make room (see
// RubyOverhang, applyRubyOverhangKerning). The one thing this view needs that the paragraph
// renderer doesn't is edgeOverflowInsets — widening itself for a run with no neighbor to kern
// (the very start/end of the surface), since this is a `.fixedSize` view with no ambient margin
// to absorb that residual the way a full-screen paragraph's container does.
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

    // Per-side padding naturalSize() added around the base text for a run that overhangs a
    // surface edge with no neighboring character to kern instead (see edgeOverflowInsets) — e.g.
    // いのち over 命, the last character of 花の命, has nothing after it to push away. Set by
    // naturalSize() and consumed by draw(_:) to inset the base text by exactly the side(s) that
    // actually needed it — left stays 0 when only the right side overflowed, so the base text
    // isn't pushed off-center by padding it never needed. Left at 0 (their default) for the
    // constrained-width sizeThatFits(_:) path, which never calls naturalSize() and so never
    // touches these — draw(_:) reproduces its old flush-at-bounds behavior exactly in that case.
    // Not private: FuriganaViewTests reads these after calling naturalSize() to verify a side
    // that doesn't need padding stays at 0, rather than only checking the total width.
    var overflowLeadingInset: CGFloat = 0
    var overflowTrailingInset: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    // Shared initialisation for both designated and coder paths so setup logic is not duplicated.
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

    // Forwards taps to the registered closure so callers can respond to user interaction without subclassing.
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

    // Recomputes intrinsic height when the layout width changes so sheet detents and parent stacks resize correctly.
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

    // `UIFont.lineHeight` is a theoretical metric, but the furigana text below is measured
    // (for its draw rect) with `NSString.size(withAttributes:)`, which reports a taller box
    // for real hiragana glyphs on some fonts/sizes. Reserving headroom from `lineHeight` while
    // measuring the actual glyph with the other API let the two numbers disagree — the reading
    // could be measured as taller than the space reserved for it, pushing its draw origin
    // above y=0, where `UIView.draw(_:)` content is silently discarded (drawing outside
    // `bounds` never reaches the view's backing store, regardless of `clipsToBounds`). Using
    // this same measurement for the reserved headroom (below, in `computeHeight`/`naturalSize`
    // too) keeps the budget and the actual draw size in agreement.
    private static func measuredLineHeight(font: UIFont) -> CGFloat {
        ("あ" as NSString).size(withAttributes: [.font: font]).height
    }

    // Renders the base text and per-run furigana annotations directly into the view's graphics context.
    override func draw(_ rect: CGRect) {
        let baseAttrString = baseAttributedString()
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * TypographySettings.furiganaSizeFactor)
        let topInset = Self.measuredLineHeight(font: furiganaFont) + gap

        let drawWidth = bounds.width > 0 ? bounds.width : rect.width
        // The base text sits below the furigana headroom, drawn in UIKit coordinates, inset by
        // whichever side(s) naturalSize() padded for edge-run overflow (0 on both sides outside
        // that path — see overflowLeadingInset's doc comment).
        let textWidth = max(0, drawWidth - overflowLeadingInset - overflowTrailingInset)
        let textRect = CGRect(x: overflowLeadingInset, y: topInset, width: textWidth, height: rect.height - topInset)

        // Draw base text using UIKit — no coordinate flip needed.
        baseAttrString.draw(in: textRect)

        let entries = runsWithReadings()
        guard entries.isEmpty == false else { return }
        let runs = entries.map(\.run)
        let runReadings = entries.map(\.reading)
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
            // Place furigana above the run rect with the configured gap. Clamped to 0 as a
            // backstop — the headroom reservation above is sized to make this a no-op in the
            // normal case, but this keeps any residual mismatch from clipping instead of just
            // sitting a hair closer to the base text than `gap` asks for.
            let furiganaY = max(0, runRect.minY - gap - furiganaSize.height)
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
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * TypographySettings.furiganaSizeFactor)
        // Reserve room for furigana text plus the gap above the first baseline.
        return ceil(size.height) + Self.measuredLineHeight(font: furiganaFont) + gap
    }

    // Computes the natural (unconstrained) size of the label — the width the text occupies
    // on a single line, and the corresponding height. Used when InlineWrapLayout asks for
    // a chip's size with no width constraint (.unspecified proposal). Most overhang is already
    // absorbed by the per-run kerning baseAttributedString() embeds (see
    // applyRubyOverhangKerning), so CTFramesetter's own natural-width measurement already
    // accounts for it; edgeOverflowInsets covers only the residual case that kerning can't —
    // a run at the very start/end of the surface, with no neighboring character to push away.
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
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * TypographySettings.furiganaSizeFactor)
        (overflowLeadingInset, overflowTrailingInset) = edgeOverflowInsets(furiganaFont: furiganaFont)
        let naturalWidth = ceil(size.width) + overflowLeadingInset + overflowTrailingInset
        let naturalHeight = ceil(size.height) + Self.measuredLineHeight(font: furiganaFont) + gap
        return CGSize(width: naturalWidth, height: naturalHeight)
    }

    // Returns each kanji run in `surface` paired with its resolved reading — explicit when
    // provided (always correct per run), else projected from the concatenated `reading` string.
    // Shared by draw(_:), applyRubyOverhangKerning, and edgeOverflowInsets so the "which runs get
    // a reading" resolution logic lives in exactly one place.
    private func runsWithReadings() -> [(run: (start: Int, end: Int), reading: String)] {
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return [] }
        let readings: [String]
        if explicitRunReadings.isEmpty == false {
            readings = runs.map { explicitRunReadings[$0.start] ?? "" }
        } else if let projected = FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: reading, runs: runs),
                  projected.count == runs.count {
            readings = projected
        } else {
            return []
        }
        return Array(zip(runs, readings))
    }

    // Mirrors KiokuCoreTextAttributedStringBuilder's inter-segment kern compensation (see
    // RubyOverhang), scoped to this surface's own internal runs: when a kanji run's ruby is
    // wider than the run itself, bump .kern on the adjoining character on each side — the run's
    // own last character to push away whatever follows (right overhang), the preceding character
    // to push the run itself right (left overhang) — so the ruby gets room without overlapping a
    // neighbor. A run with no neighbor on a given side (the very start/end of the surface) is
    // left alone here; edgeOverflowInsets widens the view for that residual instead.
    private func applyRubyOverhangKerning(to attrString: NSMutableAttributedString) {
        let furiganaFont = UIFont.systemFont(ofSize: font.pointSize * TypographySettings.furiganaSizeFactor)
        let nsSurface = surface as NSString
        let length = attrString.length
        for (run, runReading) in runsWithReadings() {
            guard runReading.isEmpty == false else { continue }
            let kanjiText = nsSurface.substring(with: NSRange(location: run.start, length: run.end - run.start))
            let kanjiWidth = (kanjiText as NSString).size(withAttributes: [.font: font]).width
            let rubyWidth = (runReading as NSString).size(withAttributes: [.font: furiganaFont]).width
            let overhang = RubyOverhang.margin(baseWidth: kanjiWidth, rubyWidth: rubyWidth)
            guard overhang > 0.5 else { continue }
            if run.end < length {
                bumpKern(in: attrString, at: run.end - 1, by: overhang)
            }
            if run.start > 0 {
                bumpKern(in: attrString, at: run.start - 1, by: overhang)
            }
        }
    }

    // Adds `amount` to whatever .kern is already set at `index` (rather than overwriting), so
    // two adjacent runs that both need room at the same boundary character (e.g. two consecutive
    // kanji runs with no kana between them) accumulate instead of one silently winning.
    private func bumpKern(in attrString: NSMutableAttributedString, at index: Int, by amount: CGFloat) {
        let existing = (attrString.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat) ?? 0
        attrString.addAttribute(.kern, value: existing + amount, range: NSRange(location: index, length: 1))
    }

    // Returns the (left, right) VIEW-LEVEL margins still needed after applyRubyOverhangKerning —
    // the one case interior kerning can't solve: a run at the very start or end of the surface,
    // with no neighboring character to push away (e.g. いのち over 命, the last character of
    // 花の命, or はかな over 儚, the first character of 儚く). KiokuCoreTextAttributedStringBuilder
    // has the same gap for a segment at the very start/end of a paragraph, but it goes unnoticed
    // there because that view's container isn't fitted tightly to its content the way this
    // `.fixedSize` view's bounds are — there's ambient margin to absorb it. This view has none,
    // so it has to make room for itself instead.
    private func edgeOverflowInsets(furiganaFont: UIFont) -> (left: CGFloat, right: CGFloat) {
        let entries = runsWithReadings()
        guard entries.isEmpty == false else { return (0, 0) }
        let length = (surface as NSString).length
        var left: CGFloat = 0
        var right: CGFloat = 0
        for (run, runReading) in entries {
            guard runReading.isEmpty == false else { continue }
            let kanjiText = (surface as NSString).substring(with: NSRange(location: run.start, length: run.end - run.start))
            let kanjiWidth = (kanjiText as NSString).size(withAttributes: [.font: font]).width
            let rubyWidth = (runReading as NSString).size(withAttributes: [.font: furiganaFont]).width
            let overhang = RubyOverhang.margin(baseWidth: kanjiWidth, rubyWidth: rubyWidth)
            guard overhang > 0.5 else { continue }
            if run.start == 0 {
                left = max(left, overhang)
            }
            if run.end == length {
                right = max(right, overhang)
            }
        }
        return (left, right)
    }

    // Builds a plain attributed string (no ruby) for CoreText base-text layout. Applies
    // per-character segment colors when segmentColors is populated, and embeds the inter-run
    // overhang kerning described at applyRubyOverhangKerning so every consumer (draw(_:),
    // computeHeight(for:), naturalSize()) measures and lays out the same widened string.
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
        applyRubyOverhangKerning(to: attrString)
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
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = self?.plainText
            }
            return UIMenu(title: "", children: [copyAction])
        }
    }
}
