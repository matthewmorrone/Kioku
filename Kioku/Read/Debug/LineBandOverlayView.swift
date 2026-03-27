import UIKit

// Lightweight UIView overlay that draws headword and furigana line bands for debug purposes.
// Used by both the read renderer and the edit view to visualise line geometry.
final class LineBandOverlayView: UIView {
    private var headwordBandRects: [CGRect] = []
    private var furiganaLineBandRects: [CGRect] = []
    private var headwordBandsEnabled = false
    private var furiganaLineBandsEnabled = false

    // Creates a transparent, non-interactive overlay surface.
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

    // Applies new band geometry and triggers a redraw when any input changes.
    func apply(
        overlayFrame: CGRect,
        headwordBandRects: [CGRect],
        furiganaLineBandRects: [CGRect],
        headwordBandsEnabled: Bool,
        furiganaLineBandsEnabled: Bool
    ) {
        frame = overlayFrame
        self.headwordBandRects = headwordBandRects
        self.furiganaLineBandRects = furiganaLineBandRects
        self.headwordBandsEnabled = headwordBandsEnabled
        self.furiganaLineBandsEnabled = furiganaLineBandsEnabled
        setNeedsDisplay()
    }

    // Draws headword bands in orange and furigana bands in blue, matching the read-mode overlay colors.
    override func draw(_ rect: CGRect) {
        UIGraphicsGetCurrentContext()?.clear(rect)

        if headwordBandsEnabled {
            UIColor.systemOrange.withAlphaComponent(0.08).setFill()
            for bandRect in headwordBandRects {
                guard bandRect.intersects(rect) else { continue }
                UIBezierPath(rect: bandRect).fill()
            }
        }

        if furiganaLineBandsEnabled {
            UIColor.systemBlue.withAlphaComponent(0.08).setFill()
            for bandRect in furiganaLineBandRects {
                guard bandRect.intersects(rect) else { continue }
                UIBezierPath(rect: bandRect).fill()
            }
        }
    }
}
