import SwiftUI

// Second half of KanjiDecoration+Canvas.swift's Canvas-based decorations, split out to stay
// under the line-count guardrail. Same rendering approach (TimelineView(.animation) +
// Canvas), just the back half of the alphabetical/thematic MARK sections — no shared state
// with the first half, each decoration struct here is independently self-contained.

// MARK: - 音 Sound

// Owned by KanjiDecoration.view(for:) — registered for the literal 音.
struct SoundDecoration: View {
    private let ringCount = 4
    private let cycleSeconds: Double = 1.8

    // Drum-burst waves — each ring expands outward from the center, fading as it
    // grows, then disappears off the edge. The previous "reflect off the screen
    // edges" version felt unintentional rather than physical; reverted to the
    // original outgoing-only pattern (with slightly more staggered timing) by
    // user request.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                let maxR = max(size.width, size.height) * 0.75

                for i in 0..<ringCount {
                    let phase = Double(i) / Double(ringCount)
                    let prog = ((t / cycleSeconds) + phase).truncatingRemainder(dividingBy: 1.0)
                    let r = CGFloat(prog) * maxR
                    let bandWidth: CGFloat = 6
                    let inner = max(0, r - bandWidth)
                    let outer = r + bandWidth
                    let alpha = 0.65 * pow(1.0 - prog, 2.2)
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: cx - outer, y: cy - outer, width: 2 * outer, height: 2 * outer))
                    ring.addEllipse(in: CGRect(x: cx - inner, y: cy - inner, width: 2 * inner, height: 2 * inner))
                    ctx.fill(ring,
                             with: .color(Color(red: 1.0, green: 0.7, blue: 0.25).opacity(alpha)),
                             style: FillStyle(eoFill: true))
                }
            }
        }
    }
}

// MARK: - 光 Light (god-rays)

// Owned by KanjiDecoration.view(for:) — registered for the literal 光.
struct LightDecoration: View {
    private let beamCount = 9

    // God-rays fanning out from the top-left corner: 9 long triangular beams
    // filled with a warm white→clear gradient, slowly rotating around the source
    // so the beams sweep through the sheet. A bright corner glow grounds the
    // light source; a soft full-sheet brightening reads as ambient illumination.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width * 0.1
                let cy = size.height * 0.08

                let glowR = max(size.width, size.height) * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: cx - glowR, y: cy - glowR, width: 2 * glowR, height: 2 * glowR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color.white.opacity(0.45),
                                Color(red: 1.0, green: 0.95, blue: 0.7).opacity(0.10),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: glowR))

                let beamLen = max(size.width, size.height) * 1.4
                let baseAngle: Double = .pi / 4
                let sweepRange: Double = 0.7
                let sweep = sin(t * 0.25) * sweepRange / 2

                for i in 0..<beamCount {
                    let spread = (Double(i) / Double(beamCount - 1)) - 0.5
                    let angle = baseAngle + spread * sweepRange + sweep
                    let halfWidth: Double = 0.025
                    let p1 = CGPoint(x: cx, y: cy)
                    let p2 = CGPoint(x: cx + CGFloat(cos(angle - halfWidth)) * beamLen,
                                     y: cy + CGFloat(sin(angle - halfWidth)) * beamLen)
                    let p3 = CGPoint(x: cx + CGFloat(cos(angle + halfWidth)) * beamLen,
                                     y: cy + CGFloat(sin(angle + halfWidth)) * beamLen)
                    var beam = Path()
                    beam.move(to: p1)
                    beam.addLine(to: p2)
                    beam.addLine(to: p3)
                    beam.closeSubpath()
                    ctx.fill(beam,
                             with: .linearGradient(
                                Gradient(colors: [
                                    Color.white.opacity(0.35),
                                    Color(red: 1.0, green: 0.95, blue: 0.7).opacity(0.05),
                                    .clear
                                ]),
                                startPoint: p1,
                                endPoint: CGPoint(x: (p2.x + p3.x) / 2, y: (p2.y + p3.y) / 2)))
                }
            }
        }
    }
}

// MARK: - 海 Sea

// Owned by KanjiDecoration.view(for:) — registered for the literal 海.
struct SeaDecoration: View {
    private let fingerCount = 9

    // Stylized after Hokusai's "Great Wave off Kanagawa" — one large Prussian-
    // blue wave dominates the foreground with a curled hooked crest on the left,
    // foam tracing the crest's edge, and small white "claw" fingers reaching
    // off the curl. A second smaller wave sits behind it for depth. The whole
    // mass swells gently up and down on a slow sine so the wave reads as alive
    // without scrolling sideways (which fought the iconic stillness of the
    // original woodblock composition).
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawBackgroundWave(ctx: ctx, size: size, t: t)
                drawMainWave(ctx: ctx, size: size, t: t)
            }
        }
    }

    // The hero wave: rises steeply from the left, peaks high, then the crest
    // hooks to the right with a clear curl shape before dropping off down the
    // right side of the sheet. Filled with deep Prussian blue (the signature
    // color of the woodblock). All coordinates are proportional to size so the
    // wave scales with the sheet.
    private func drawMainWave(ctx: GraphicsContext, size: CGSize, t: Double) {
        let swell = CGFloat(sin(t * 0.45) * 5)
        let baseY = size.height * 0.50 + swell

        // Key wave anchor points — proportional, so the curl reads at any sheet size.
        let leftBase = CGPoint(x: -10, y: baseY + 30)
        let peak = CGPoint(x: size.width * 0.30, y: size.height * 0.10 + swell)
        let curlOuter = CGPoint(x: size.width * 0.46, y: size.height * 0.16 + swell)
        let curlTip = CGPoint(x: size.width * 0.55, y: size.height * 0.27 + swell)
        let postCurl = CGPoint(x: size.width * 0.60, y: size.height * 0.42 + swell)
        let rightDescent = CGPoint(x: size.width + 10, y: size.height * 0.55 + swell)

        var wave = Path()
        wave.move(to: leftBase)
        // Steep climb to the peak.
        wave.addCurve(to: peak,
                      control1: CGPoint(x: size.width * 0.08, y: baseY - 10),
                      control2: CGPoint(x: size.width * 0.20, y: peak.y + 40))
        // Crest rolls to the right.
        wave.addQuadCurve(to: curlOuter,
                          control: CGPoint(x: size.width * 0.38, y: peak.y - 8))
        // Curl tip — drops down and right.
        wave.addQuadCurve(to: curlTip,
                          control: CGPoint(x: curlOuter.x + 20, y: curlOuter.y + 5))
        // Behind the curl, drop into the post-curl trough.
        wave.addCurve(to: postCurl,
                      control1: CGPoint(x: curlTip.x + 6, y: curlTip.y + 28),
                      control2: CGPoint(x: postCurl.x - 6, y: postCurl.y - 18))
        // Descend toward the right edge.
        wave.addCurve(to: rightDescent,
                      control1: CGPoint(x: size.width * 0.75, y: postCurl.y - 8),
                      control2: CGPoint(x: size.width * 0.92, y: rightDescent.y - 6))
        // Close to bottom.
        wave.addLine(to: CGPoint(x: rightDescent.x, y: size.height + 10))
        wave.addLine(to: CGPoint(x: leftBase.x, y: size.height + 10))
        wave.closeSubpath()
        ctx.fill(wave, with: .color(Color(red: 0.08, green: 0.22, blue: 0.44).opacity(0.90)))

        // Foam crest stroke — a thick white line tracing the upper edge of the
        // wave from the peak around the curl. This is what makes the wave read
        // as breaking rather than just a blue mound.
        var foam = Path()
        foam.move(to: peak)
        foam.addQuadCurve(to: curlOuter,
                          control: CGPoint(x: size.width * 0.38, y: peak.y - 8))
        foam.addQuadCurve(to: curlTip,
                          control: CGPoint(x: curlOuter.x + 20, y: curlOuter.y + 5))
        ctx.stroke(foam,
                   with: .color(.white.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

        // Foam fingers — small white droplet shapes flung off the curl, the
        // signature "claw" element of the Hokusai wave. They pulse slightly so
        // the spray feels alive.
        for i in 0..<fingerCount {
            let progress = Double(i) / Double(fingerCount - 1)
            let attachX = peak.x + (curlTip.x - peak.x) * CGFloat(progress)
            let attachY = peak.y + (curlTip.y - peak.y) * CGFloat(progress * progress)
            let pulse = 0.55 + 0.45 * sin(t * 1.6 + Double(i) * 0.7)
            let fingerAngle = -Double.pi * 0.55 + progress * 0.6
            let fingerLen: CGFloat = 12 + CGFloat(pulse) * 16
            let endX = attachX + CGFloat(cos(fingerAngle)) * fingerLen
            let endY = attachY + CGFloat(sin(fingerAngle)) * fingerLen
            // Tapered finger: thick attached end, thinner tip.
            var finger = Path()
            finger.move(to: CGPoint(x: attachX, y: attachY))
            finger.addQuadCurve(to: CGPoint(x: endX, y: endY),
                                control: CGPoint(x: (attachX + endX) / 2 + 4,
                                                 y: (attachY + endY) / 2 - 2))
            ctx.stroke(finger,
                       with: .color(.white.opacity(0.85 * pulse)),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            // Droplet at the tip.
            let dotR: CGFloat = 2.2 * CGFloat(pulse)
            ctx.fill(Path(ellipseIn: CGRect(x: endX - dotR, y: endY - dotR, width: 2 * dotR, height: 2 * dotR)),
                     with: .color(.white.opacity(0.9 * pulse)))
        }
    }

    // A smaller, paler wave behind the main one for the layered depth Hokusai
    // composes through. Same hook silhouette but scaled down and shifted right,
    // with a slightly different swell phase so the two waves breathe at offset
    // times rather than in lockstep.
    private func drawBackgroundWave(ctx: GraphicsContext, size: CGSize, t: Double) {
        let swell = CGFloat(sin(t * 0.32 + 1.5) * 4)
        let baseY = size.height * 0.42 + swell

        let leftBase = CGPoint(x: size.width * 0.40, y: baseY + 20)
        let peak = CGPoint(x: size.width * 0.62, y: size.height * 0.20 + swell)
        let curlTip = CGPoint(x: size.width * 0.82, y: size.height * 0.30 + swell)
        let rightDescent = CGPoint(x: size.width + 10, y: size.height * 0.46 + swell)

        var wave = Path()
        wave.move(to: leftBase)
        wave.addCurve(to: peak,
                      control1: CGPoint(x: size.width * 0.45, y: baseY - 10),
                      control2: CGPoint(x: size.width * 0.55, y: peak.y + 30))
        wave.addQuadCurve(to: curlTip,
                          control: CGPoint(x: size.width * 0.72, y: peak.y - 4))
        wave.addCurve(to: rightDescent,
                      control1: CGPoint(x: curlTip.x + 6, y: curlTip.y + 24),
                      control2: CGPoint(x: size.width * 0.92, y: rightDescent.y - 6))
        wave.addLine(to: CGPoint(x: rightDescent.x, y: size.height + 10))
        wave.addLine(to: CGPoint(x: leftBase.x, y: size.height + 10))
        wave.closeSubpath()
        ctx.fill(wave, with: .color(Color(red: 0.18, green: 0.36, blue: 0.60).opacity(0.55)))

        // Light foam line along the background wave's crest.
        var foam = Path()
        foam.move(to: peak)
        foam.addQuadCurve(to: curlTip,
                          control: CGPoint(x: size.width * 0.72, y: peak.y - 4))
        ctx.stroke(foam,
                   with: .color(.white.opacity(0.65)),
                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
}
