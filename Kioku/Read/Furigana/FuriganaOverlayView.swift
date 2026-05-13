import UIKit

// Draws the read-mode furigana overlay as a single lightweight surface instead of many UILabel subviews.
final class FuriganaOverlayView: UIView {
    private var selectedSegmentRect: CGRect?
    private var selectedSegmentColor: UIColor?
    private var playbackHighlightRect: CGRect?
    private var playbackHighlightColor: UIColor?
    private var illegalBoundaryRect: CGRect?
    private var illegalBoundaryColor: UIColor?
    private var furiganaStrings: [String] = []
    private var furiganaFrames: [CGRect] = []
    private var furiganaColors: [UIColor] = []
    private var furiganaFont: UIFont = .systemFont(ofSize: 12)
    // Debug overlay data — empty/false when debug settings are off.
    private var debugFuriganaRectsEnabled = false
    private var debugHeadwordRectsEnabled = false
    private var debugHeadwordRects: [CGRect] = []
    private var debugHeadwordColors: [UIColor] = []
    private var debugHeadwordLineBands: [CGRect] = []
    private var debugFuriganaLineBands: [CGRect] = []
    private var debugHeadwordLineBandsEnabled = false
    private var debugFuriganaLineBandsEnabled = false
    // Envelope debug data — bounding box spanning both headword and furigana.
    private var debugEnvelopeRectsEnabled = false
    private var debugEnvelopeRects: [CGRect] = []
    // Bisector debug data — vertical center lines showing headword/furigana alignment.
    private var debugBisectorHeadwordEnabled = false
    private var debugBisectorFuriganaEnabled = false
    private var debugBisectorHeadwordMidXs: [CGFloat] = []
    private var debugBisectorHeadwordRects: [CGRect] = []
    private var debugBisectorFuriganaRects: [CGRect] = []
    // Left inset guide — a single vertical line at the container's left inset so the
    // reader can visually verify whether line-start envelopes (especially wide-ruby
    // ones) align with the canonical left edge of text. nil when disabled.
    private var debugLeftInsetGuideX: CGFloat?

    // Creates the overlay surface used by the read renderer.
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    // Rejects storyboard initialization because the overlay is created programmatically.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Applies the latest overlay geometry and invalidates drawing only when read-mode visuals change.
    func apply(
        overlayFrame: CGRect,
        selectedSegmentRect: CGRect?,
        selectedSegmentColor: UIColor?,
        playbackHighlightRect: CGRect?,
        playbackHighlightColor: UIColor?,
        illegalBoundaryRect: CGRect?,
        illegalBoundaryColor: UIColor?,
        furiganaStrings: [String],
        furiganaFrames: [CGRect],
        furiganaColors: [UIColor],
        furiganaFont: UIFont,
        debugFuriganaRectsEnabled: Bool,
        debugHeadwordRectsEnabled: Bool,
        debugHeadwordLineBandsEnabled: Bool,
        debugFuriganaLineBandsEnabled: Bool,
        debugHeadwordRects: [CGRect],
        debugHeadwordColors: [UIColor],
        debugHeadwordLineBandRects: [CGRect],
        debugFuriganaLineBandRects: [CGRect],
        debugBisectorHeadwordEnabled: Bool = false,
        debugBisectorFuriganaEnabled: Bool = false,
        debugBisectorHeadwordMidXs: [CGFloat] = [],
        debugBisectorHeadwordRects: [CGRect] = [],
        debugBisectorFuriganaRects: [CGRect] = [],
        debugEnvelopeRectsEnabled: Bool = false,
        debugEnvelopeRects: [CGRect] = [],
        debugLeftInsetGuideX: CGFloat? = nil
    ) {
        frame = overlayFrame
        self.selectedSegmentRect = selectedSegmentRect
        self.selectedSegmentColor = selectedSegmentColor
        self.playbackHighlightRect = playbackHighlightRect
        self.playbackHighlightColor = playbackHighlightColor
        self.illegalBoundaryRect = illegalBoundaryRect
        self.illegalBoundaryColor = illegalBoundaryColor
        self.furiganaStrings = furiganaStrings
        self.furiganaFrames = furiganaFrames
        self.furiganaColors = furiganaColors
        self.furiganaFont = furiganaFont


        self.debugHeadwordRects = debugHeadwordRects
        self.debugHeadwordColors = debugHeadwordColors
        self.debugFuriganaRectsEnabled = debugFuriganaRectsEnabled
        self.debugHeadwordRectsEnabled = debugHeadwordRectsEnabled
        self.debugEnvelopeRects = debugEnvelopeRects
        self.debugEnvelopeRectsEnabled = debugEnvelopeRectsEnabled
        self.debugHeadwordLineBands = debugHeadwordLineBandRects
        self.debugHeadwordLineBandsEnabled = debugHeadwordLineBandsEnabled
        self.debugFuriganaLineBands = debugFuriganaLineBandRects
        self.debugFuriganaLineBandsEnabled = debugFuriganaLineBandsEnabled
        self.debugBisectorHeadwordEnabled = debugBisectorHeadwordEnabled
        self.debugBisectorFuriganaEnabled = debugBisectorFuriganaEnabled
        self.debugBisectorHeadwordMidXs = debugBisectorHeadwordMidXs
        self.debugBisectorHeadwordRects = debugBisectorHeadwordRects
        self.debugBisectorFuriganaRects = debugBisectorFuriganaRects
        self.debugLeftInsetGuideX = debugLeftInsetGuideX
        setNeedsDisplay()
    }

    // Draws highlights, merge markers, furigana labels, and optional debug overlays in text-view coordinates.
    override func draw(_ rect: CGRect) {
        // Clears stale overlay fragments from prior frames before redrawing the current dirty region.
        UIGraphicsGetCurrentContext()?.clear(rect)

        // Headword line bands drawn first so all other overlays render on top.
        if debugHeadwordLineBandsEnabled {
            UIColor.systemOrange.withAlphaComponent(0.08).setFill()
            for bandRect in debugHeadwordLineBands {
                guard bandRect.intersects(rect) else { continue }
                UIBezierPath(rect: bandRect).fill()
            }
        }

        // Furigana line bands sit directly above their corresponding headword rows.
        if debugFuriganaLineBandsEnabled {
            UIColor.systemBlue.withAlphaComponent(0.08).setFill()
            for bandRect in debugFuriganaLineBands {
                guard bandRect.intersects(rect) else { continue }
                UIBezierPath(rect: bandRect).fill()
            }
        }

        // Left inset guide: a single vertical line at the text container's left
        // inset position in text-view coordinates. Drawn immediately after the
        // bands so all dashed overlays render on top, and line-start segments
        // with wide ruby can be visually compared against the canonical left
        // edge of the text column.
        if let guideX = debugLeftInsetGuideX {
            UIColor.systemRed.withAlphaComponent(0.9).setStroke()
            let guidePath = UIBezierPath()
            guidePath.move(to: CGPoint(x: guideX, y: bounds.minY))
            guidePath.addLine(to: CGPoint(x: guideX, y: bounds.maxY))
            guidePath.lineWidth = 1
            guidePath.stroke()
        }

        if let selectedSegmentRect, let selectedSegmentColor, selectedSegmentRect.intersects(rect) {
            selectedSegmentColor.setFill()
            UIBezierPath(roundedRect: selectedSegmentRect, cornerRadius: 4).fill()
        }

        if let playbackHighlightRect, let playbackHighlightColor, playbackHighlightRect.intersects(rect) {
            playbackHighlightColor.setFill()
            UIBezierPath(roundedRect: playbackHighlightRect, cornerRadius: 10).fill()
        }

        if let illegalBoundaryRect, let illegalBoundaryColor, illegalBoundaryRect.intersects(rect) {
            illegalBoundaryColor.setFill()
            UIBezierPath(roundedRect: illegalBoundaryRect, cornerRadius: 1.5).fill()
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        for index in furiganaFrames.indices {
            let furiganaFrame = furiganaFrames[index]
            if furiganaFrame.intersects(rect) == false {
                continue
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: furiganaFont,
                .foregroundColor: furiganaColors[index],
                .paragraphStyle: paragraphStyle,
            ]
            (furiganaStrings[index] as NSString).draw(in: furiganaFrame, withAttributes: attributes)
        }

        // Headword debug rects drawn as dashed outlines colored to match the segment's text color.
        if debugHeadwordRectsEnabled {
            for (index, headwordRect) in debugHeadwordRects.enumerated() {
                guard headwordRect.intersects(rect) else { continue }
                let color = index < debugHeadwordColors.count
                    ? debugHeadwordColors[index].withAlphaComponent(0.7)
                    : UIColor.label.withAlphaComponent(0.7)
                color.setStroke()
                let path = UIBezierPath(rect: headwordRect.insetBy(dx: 0.5, dy: 0.5))
                path.setLineDash([3, 2], count: 2, phase: 0)
                path.lineWidth = 1
                path.stroke()
            }
        }

        // Furigana debug rects drawn as dashed outlines using the same segment color.
        if debugFuriganaRectsEnabled {
            for (index, furiganaFrame) in furiganaFrames.enumerated() {
                guard furiganaFrame.intersects(rect) else { continue }
                let color = index < furiganaColors.count
                    ? furiganaColors[index].withAlphaComponent(0.7)
                    : UIColor.systemCyan.withAlphaComponent(0.7)
                color.setStroke()
                let path = UIBezierPath(rect: furiganaFrame.insetBy(dx: 0.5, dy: 0.5))
                path.setLineDash([3, 2], count: 2, phase: 0)
                path.lineWidth = 1
                path.stroke()
            }
        }

        // Envelope rects: dashed outline spanning the full headword+furigana bounding box.
        if debugEnvelopeRectsEnabled {
            UIColor.systemPurple.withAlphaComponent(0.8).setStroke()
            for envelopeRect in debugEnvelopeRects {
                guard envelopeRect.intersects(rect) else { continue }
                let path = UIBezierPath(rect: envelopeRect.insetBy(dx: 0.5, dy: 0.5))
                path.setLineDash([4, 2], count: 2, phase: 0)
                path.lineWidth = 1
                path.stroke()
            }
        }

        // Bisectors: each toggle draws independently. Headword line through the kanji-run
        // center, furigana line through the ruby center. When both toggles are on, the
        // pair color-codes by alignment (yellow=aligned within 0.75pt, green=misaligned).
        // When only one is on, that lone line is yellow so it remains visible against any
        // backdrop.
        let drawAnyBisector = debugBisectorHeadwordEnabled || debugBisectorFuriganaEnabled
        if drawAnyBisector {
            let tolerance: CGFloat = 0.75
            for index in debugBisectorHeadwordMidXs.indices {
                let headwordRect = debugBisectorHeadwordRects[index]
                let furiganaRect = debugBisectorFuriganaRects[index]
                let headwordMidX = debugBisectorHeadwordMidXs[index]
                let hasFurigana = furiganaRect != .zero

                let pairColor: UIColor
                if hasFurigana, debugBisectorHeadwordEnabled, debugBisectorFuriganaEnabled {
                    let aligned = abs(headwordMidX - furiganaRect.midX) <= tolerance
                    pairColor = aligned
                        ? UIColor.systemYellow.withAlphaComponent(0.9)
                        : UIColor.systemGreen.withAlphaComponent(0.9)
                } else {
                    pairColor = UIColor.systemYellow.withAlphaComponent(0.9)
                }
                pairColor.setStroke()

                if debugBisectorHeadwordEnabled {
                    let headwordPath = UIBezierPath()
                    headwordPath.move(to: CGPoint(x: headwordMidX, y: headwordRect.minY))
                    headwordPath.addLine(to: CGPoint(x: headwordMidX, y: headwordRect.maxY))
                    headwordPath.lineWidth = 2
                    headwordPath.stroke()
                }
                if debugBisectorFuriganaEnabled, hasFurigana {
                    let furiganaPath = UIBezierPath()
                    furiganaPath.move(to: CGPoint(x: furiganaRect.midX, y: furiganaRect.minY))
                    furiganaPath.addLine(to: CGPoint(x: furiganaRect.midX, y: furiganaRect.maxY))
                    furiganaPath.lineWidth = 2
                    furiganaPath.stroke()
                }
            }
        }
    }
}
