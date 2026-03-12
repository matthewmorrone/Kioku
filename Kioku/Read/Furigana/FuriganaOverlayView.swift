import UIKit

// Draws the read-mode furigana overlay as a single lightweight surface instead of many UILabel subviews.
final class FuriganaOverlayView: UIView {
    private var selectedSegmentRect: CGRect?
    private var selectedSegmentColor: UIColor?
    private var illegalBoundaryRect: CGRect?
    private var illegalBoundaryColor: UIColor?
    private var furiganaStrings: [String] = []
    private var furiganaFrames: [CGRect] = []
    private var furiganaColors: [UIColor] = []
    private var furiganaFont: UIFont = .systemFont(ofSize: 12)

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
        illegalBoundaryRect: CGRect?,
        illegalBoundaryColor: UIColor?,
        furiganaStrings: [String],
        furiganaFrames: [CGRect],
        furiganaColors: [UIColor],
        furiganaFont: UIFont
    ) {
        frame = overlayFrame
        self.selectedSegmentRect = selectedSegmentRect
        self.selectedSegmentColor = selectedSegmentColor
        self.illegalBoundaryRect = illegalBoundaryRect
        self.illegalBoundaryColor = illegalBoundaryColor
        self.furiganaStrings = furiganaStrings
        self.furiganaFrames = furiganaFrames
        self.furiganaColors = furiganaColors
        self.furiganaFont = furiganaFont
        setNeedsDisplay()
    }

    // Draws highlights, merge markers, and furigana labels in text-view coordinates so scrolling stays compositor-friendly.
    override func draw(_ rect: CGRect) {
        if let selectedSegmentRect, let selectedSegmentColor, selectedSegmentRect.intersects(rect) {
            selectedSegmentColor.setFill()
            UIBezierPath(roundedRect: selectedSegmentRect, cornerRadius: 4).fill()
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
    }
}