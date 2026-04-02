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
    private var debugHeadwordLineBandsEnabled = false
    private var debugFuriganaLineBandsEnabled = false
    private var debugHeadwordRects: [CGRect] = []
    private var debugHeadwordColors: [UIColor] = []
    private var debugHeadwordLineBandRects: [CGRect] = []
    private var debugFuriganaLineBandRects: [CGRect] = []

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
        debugFuriganaLineBandRects: [CGRect]
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
        self.debugFuriganaRectsEnabled = debugFuriganaRectsEnabled
        self.debugHeadwordRectsEnabled = debugHeadwordRectsEnabled
        self.debugHeadwordLineBandsEnabled = debugHeadwordLineBandsEnabled
        self.debugFuriganaLineBandsEnabled = debugFuriganaLineBandsEnabled
        self.debugHeadwordRects = debugHeadwordRects
        self.debugHeadwordColors = debugHeadwordColors
        self.debugHeadwordLineBandRects = debugHeadwordLineBandRects
        self.debugFuriganaLineBandRects = debugFuriganaLineBandRects
        setNeedsDisplay()
    }

    // Draws highlights, merge markers, furigana labels, and optional debug overlays in text-view coordinates.
    override func draw(_ rect: CGRect) {
        // Clears stale overlay fragments from prior frames before redrawing the current dirty region.
        UIGraphicsGetCurrentContext()?.clear(rect)

        // Headword line bands drawn first so all other overlays render on top.
        if debugHeadwordLineBandsEnabled {
            UIColor.systemOrange.withAlphaComponent(0.08).setFill()
            for bandRect in debugHeadwordLineBandRects {
                guard bandRect.intersects(rect) else { continue }
                UIBezierPath(rect: bandRect).fill()
            }
        }

        // Furigana line bands sit directly above their corresponding headword rows.
        if debugFuriganaLineBandsEnabled {
            UIColor.systemBlue.withAlphaComponent(0.08).setFill()
            for bandRect in debugFuriganaLineBandRects {
                guard bandRect.intersects(rect) else { continue }
                UIBezierPath(rect: bandRect).fill()
            }
        }

        if let selectedSegmentRect, let selectedSegmentColor, selectedSegmentRect.intersects(rect) {
            selectedSegmentColor.setFill()
            UIBezierPath(roundedRect: selectedSegmentRect, cornerRadius: 4).fill()
        }

        if let playbackHighlightRect, let playbackHighlightColor, playbackHighlightRect.intersects(rect) {
            playbackHighlightColor.setFill()
            UIBezierPath(roundedRect: playbackHighlightRect, cornerRadius: 7).fill()
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
    }
}
