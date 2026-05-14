import UIKit

// Draws the dev-only debug overlays for the CoreText Read renderer. Mirrors the
// semantics of FuriganaOverlayView's debug branch:
//   - Line bands tint the headword / furigana regions of each line
//   - Headword / furigana rects show per-segment glyph extents
//   - Envelope rects show the (headword ∪ furigana) union — the same envelope used
//     for selection / hit testing in TK2
//   - Bisectors draw a vertical line at the geometric center of each kanji run; the
//     headword and furigana bisectors coincide (CTRubyAnnotation `.center`), so
//     when both toggles are on the line is yellow (aligned). Drift would surface
//     as a green line — a future regression signal if ruby alignment changes.
//   - Pixel ruler draws a faint 10pt grid for hand-measuring layouts
//   - Left-inset guide marks the content-inset boundary
//   - Illegal-merge boundary draws a red bar at the bisector of a flagged segment
final class KiokuDebugOverlayView: UIView {

    struct Flags: Equatable {
        var headwordRects: Bool = false
        var furiganaRects: Bool = false
        var envelopeRects: Bool = false
        var headwordBisectors: Bool = false
        var furiganaBisectors: Bool = false
        var headwordLineBands: Bool = false
        var furiganaLineBands: Bool = false
        var pixelRuler: Bool = false
        var leftInsetGuide: Bool = false
        // Show "L0", "L1", ... labels at the left edge of each headword line so the
        // visual line index matches up with what tap-routing / engine logs report.
        var headwordLineNumbers: Bool = false
        // Show "R0", "R1", ... labels at the left edge of each ruby (furigana) line.
        // Useful when chasing per-line ruby drift or atomic-wrap regressions.
        var rubyLineNumbers: Bool = false
    }

    var flags = Flags() { didSet { if oldValue != flags { setNeedsDisplay() } } }
    var segmentGeometry: [KiokuDebugOverlayGeometry.SegmentGeometry] = [] {
        didSet { setNeedsDisplay() }
    }
    var lineGeometry: [KiokuDebugOverlayGeometry.LineGeometry] = [] {
        didSet { setNeedsDisplay() }
    }
    var leftInsetX: CGFloat = 0 {
        didSet { if oldValue != leftInsetX { setNeedsDisplay() } }
    }
    // Location of an illegal-merge boundary, when one is active. Drawn as a red
    // vertical bar at that segment's bisector. Nil disables the marker.
    var illegalMergeLocation: Int? {
        didSet { if oldValue != illegalMergeLocation { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Paints all enabled debug overlays in layered order: bands behind, envelope /
    // headword / furigana rects, bisectors, illegal-merge marker, inset guide, and the
    // pixel ruler on top. Each layer respects its toggle in `flags`.
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // 1. Line bands (back layer, low alpha so other overlays remain readable)
        if flags.headwordLineBands {
            UIColor.systemBlue.withAlphaComponent(0.08).setFill()
            for line in lineGeometry { UIBezierPath(rect: line.headwordBandRect).fill() }
        }
        if flags.furiganaLineBands {
            UIColor.systemPink.withAlphaComponent(0.10).setFill()
            for line in lineGeometry { UIBezierPath(rect: line.furiganaBandRect).fill() }
        }

        // 2. Line-number labels. "L#" pill at the left edge of each headword baseline;
        //    "R#" pill at the left edge of each ruby baseline. Each label gets an opaque
        //    dark background so it stays readable over kanji glyphs (the labels overlap
        //    the first character of every line by design — there's no gutter). The
        //    label's BASELINE is aligned with the ROW it annotates so the eye can scan
        //    across to the actual headword / ruby content.
        if flags.headwordLineNumbers || flags.rubyLineNumbers {
            let labelFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let padX: CGFloat = 3
            let padY: CGFloat = 1
            let corner: CGFloat = 3
            for (index, line) in lineGeometry.enumerated() {
                if flags.headwordLineNumbers {
                    drawLineNumberPill(
                        text: "L\(index)",
                        font: labelFont,
                        textColor: .white,
                        backgroundColor: UIColor.systemBlue.withAlphaComponent(0.92),
                        topLeft: CGPoint(x: 0, y: line.headwordBandRect.minY),
                        padX: padX,
                        padY: padY,
                        cornerRadius: corner,
                        in: ctx
                    )
                }
                if flags.rubyLineNumbers {
                    drawLineNumberPill(
                        text: "R\(index)",
                        font: labelFont,
                        textColor: .white,
                        backgroundColor: UIColor.systemPink.withAlphaComponent(0.92),
                        topLeft: CGPoint(x: 0, y: line.furiganaBandRect.minY),
                        padX: padX,
                        padY: padY,
                        cornerRadius: corner,
                        in: ctx
                    )
                }
            }
        }

        // Left-inset guide. Matches TK2's FuriganaOverlayView style (solid red, 1pt)
        // so direct visual comparison stays straightforward. Painted LAST so other
        // overlays can't accidentally draw over it.
        // (Implemented at bottom of this method.)

        // 3. Envelope rects (drawn before headword/furigana so those overlay on top)
        if flags.envelopeRects {
            ctx.setStrokeColor(UIColor.systemPurple.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            for seg in segmentGeometry {
                ctx.stroke(seg.envelopeRect)
            }
        }

        // 4. Headword rects (dashed, per segment) — uses the actual `firstRect`
        //    output, so the rect aligns with the rendered glyphs by construction.
        if flags.headwordRects {
            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            for seg in segmentGeometry { ctx.stroke(seg.headwordRect) }
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // 5. Furigana rects (dashed, only for segments with ruby)
        if flags.furiganaRects {
            ctx.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            for seg in segmentGeometry {
                if let r = seg.furiganaRect { ctx.stroke(r) }
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Bisectors. Each toggle is independent so misalignment between the kanji-run
        // center and the ruby center is directly visible. When both are on, the pair
        // color-codes by alignment (yellow when within 0.75pt, green when not); when
        // only one is on, that lone line draws in yellow.
        let drawAnyBisector = flags.headwordBisectors || flags.furiganaBisectors
        if drawAnyBisector {
            ctx.setLineWidth(1)
            let tolerance: CGFloat = 0.75
            for seg in segmentGeometry {
                guard let furi = seg.furiganaRect else { continue }
                let headwordMidX = seg.bisectorX
                let furiganaMidX = furi.midX
                let pairColor: UIColor
                if flags.headwordBisectors, flags.furiganaBisectors {
                    pairColor = abs(headwordMidX - furiganaMidX) <= tolerance
                        ? UIColor.systemYellow.withAlphaComponent(0.9)
                        : UIColor.systemGreen.withAlphaComponent(0.9)
                } else {
                    pairColor = UIColor.systemYellow.withAlphaComponent(0.9)
                }
                ctx.setStrokeColor(pairColor.cgColor)
                if flags.headwordBisectors {
                    ctx.move(to: CGPoint(x: headwordMidX, y: seg.headwordRect.minY))
                    ctx.addLine(to: CGPoint(x: headwordMidX, y: seg.headwordRect.maxY))
                    ctx.strokePath()
                }
                if flags.furiganaBisectors {
                    ctx.move(to: CGPoint(x: furiganaMidX, y: furi.minY))
                    ctx.addLine(to: CGPoint(x: furiganaMidX, y: furi.maxY))
                    ctx.strokePath()
                }
            }
        }

        // 7. Illegal merge marker — a red bar at the segment's bisector spanning
        //    the entire envelope. Stands out against any color combination.
        if let illegal = illegalMergeLocation,
           let seg = segmentGeometry.first(where: { $0.location == illegal }) {
            ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.6).cgColor)
            let bar = CGRect(
                x: seg.bisectorX - 1.5,
                y: seg.envelopeRect.minY,
                width: 3,
                height: seg.envelopeRect.height
            )
            ctx.fill(bar)
        }

        // Left-inset guide (painted late so other rects can't accidentally cover it).
        if flags.leftInsetGuide {
            ctx.setStrokeColor(UIColor.systemRed.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: leftInsetX, y: 0))
            ctx.addLine(to: CGPoint(x: leftInsetX, y: bounds.height))
            ctx.strokePath()
        }

        // Pixel ruler (top layer — drawn last so it sits on everything else)
        if flags.pixelRuler {
            ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(0.5)
            let step: CGFloat = 10
            var x: CGFloat = 0
            while x <= bounds.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= bounds.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += step
            }
            ctx.strokePath()
        }
    }

    // Draws a label string inside a rounded-rect pill with high-contrast text. Used for
    // the L# / R# line-number annotations so they stay readable when overlapping kanji.
    private func drawLineNumberPill(
        text: String,
        font: UIFont,
        textColor: UIColor,
        backgroundColor: UIColor,
        topLeft: CGPoint,
        padX: CGFloat,
        padY: CGFloat,
        cornerRadius: CGFloat,
        in ctx: CGContext
    ) {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let pillRect = CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: ceil(textSize.width) + padX * 2,
            height: ceil(textSize.height) + padY * 2
        )
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: cornerRadius)
        ctx.setFillColor(backgroundColor.cgColor)
        ctx.addPath(pillPath.cgPath)
        ctx.fillPath()
        let textOrigin = CGPoint(x: pillRect.minX + padX, y: pillRect.minY + padY)
        (text as NSString).draw(
            at: textOrigin,
            withAttributes: [.font: font, .foregroundColor: textColor]
        )
    }
}
