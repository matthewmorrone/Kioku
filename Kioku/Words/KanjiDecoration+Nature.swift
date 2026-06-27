import SwiftUI

// Nature decorations — landscape, weather variants, and plant-life kanji.
// Most are Canvas-based; the few that share visual primitives (mountain peaks,
// scrolling clouds, leaf drift) use small inline helpers to keep each kanji's
// view structurally clear.

// MARK: - 山 Mountain

// Owned by KanjiDecoration.view(for:) — registered for the literal 山.
struct MountainDecoration: View {
    // Mt. Fuji silhouette — single tall symmetric peak with the iconic concave
    // slopes (the slope curves gently inward, not the convex bulge of a generic
    // mountain), and a snow-capped top. A drifting cloud passes in front of
    // the peak, the way real Fuji is usually wreathed.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let baseY = size.height * 0.95
                let summitX = size.width * 0.50
                let summitY = size.height * 0.18
                let halfBaseWidth = size.width * 0.55
                let snowLine = summitY + (baseY - summitY) * 0.25  // snowcap fills ~top quarter

                // Fuji silhouette with concave slopes — quadratic Bezier with
                // control points pulled OUTWARD from the peak-to-base line so
                // the slopes bow gently away from the apex.
                let leftBase = CGPoint(x: summitX - halfBaseWidth, y: baseY)
                let rightBase = CGPoint(x: summitX + halfBaseWidth, y: baseY)
                let summit = CGPoint(x: summitX, y: summitY)
                var fuji = Path()
                fuji.move(to: leftBase)
                fuji.addQuadCurve(to: summit,
                                  control: CGPoint(x: summitX - halfBaseWidth * 0.45, y: baseY - (baseY - summitY) * 0.85))
                fuji.addQuadCurve(to: rightBase,
                                  control: CGPoint(x: summitX + halfBaseWidth * 0.45, y: baseY - (baseY - summitY) * 0.85))
                fuji.addLine(to: CGPoint(x: rightBase.x, y: size.height))
                fuji.addLine(to: CGPoint(x: leftBase.x, y: size.height))
                fuji.closeSubpath()
                ctx.fill(fuji, with: .color(Color(red: 0.32, green: 0.38, blue: 0.50).opacity(0.85)))

                // Snowcap — same silhouette clipped to the top quarter, filled white.
                ctx.drawLayer { layer in
                    layer.clip(to: fuji)
                    let snowRect = CGRect(x: 0, y: 0, width: size.width, height: snowLine)
                    layer.fill(Path(snowRect),
                               with: .color(Color(white: 0.96).opacity(0.95)))
                }

                // Drifting cloud in front of the peak.
                let scrollX = CGFloat(t * 6).truncatingRemainder(dividingBy: size.width + 200) - 100
                drawCloud(ctx: ctx, center: CGPoint(x: scrollX, y: size.height * 0.28),
                          width: 130, alpha: 0.55)
            }
        }
    }
}

// MARK: - 川 River

// Owned by KanjiDecoration.view(for:) — registered for the literal 川.
struct RiverDecoration: View {
    // Horizontal wavy water band across the middle of the sheet, scrolling
    // left-to-right (the current). Foam dots ride along the surface so the
    // water looks like it's moving, not just present.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let centerY = size.height * 0.52
                let amp: CGFloat = 12
                let wavelength: CGFloat = 90
                let speed: Double = 30.0
                let offset = CGFloat(t * speed).truncatingRemainder(dividingBy: wavelength)

                // Water body: a tall band with sine waves on top and bottom edges.
                let topMid = centerY - 25
                let botMid = centerY + 25
                var path = Path()
                path.move(to: CGPoint(x: 0, y: topMid))
                var x: CGFloat = 0
                while x <= size.width {
                    let y = topMid + amp * 0.5 * CGFloat(sin(Double((x + offset) / wavelength) * 2 * .pi))
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 4
                }
                x = size.width
                while x >= 0 {
                    let y = botMid + amp * 0.5 * CGFloat(sin(Double((x - offset) / wavelength) * 2 * .pi + .pi))
                    path.addLine(to: CGPoint(x: x, y: y))
                    x -= 4
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(Color(red: 0.20, green: 0.50, blue: 0.85).opacity(0.55)))

                // Foam dots scrolling along the surface.
                for i in 0..<22 {
                    let foamSeed = kanjiSeedFraction(i, 7)
                    let foamX = CGFloat((foamSeed * Double(size.width) + Double(t * speed * 1.1))
                        .truncatingRemainder(dividingBy: Double(size.width)))
                    let foamY = topMid + amp * 0.5 * CGFloat(sin(Double((foamX + offset) / wavelength) * 2 * .pi))
                    let r: CGFloat = 1.3 + CGFloat(kanjiSeedFraction(i, 11)) * 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: foamX - r, y: foamY - r, width: 2 * r, height: 2 * r)),
                             with: .color(.white.opacity(0.85)))
                }
            }
        }
    }
}

// MARK: - 空 Sky

// Owned by KanjiDecoration.view(for:) — registered for the literal 空.
struct SkyDecoration: View {
    private let birdCount = 4

    // 空 means both "sky" AND "empty / air" — render OPENNESS, not clouds. A
    // blue-to-pale gradient fills the sheet (atmosphere itself), and a few
    // small bird silhouettes glide through to give the eye a sense of scale
    // without anything else to look at. Distinct from 雲's cloud-mass shape.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Open-sky gradient — saturated at top, pale at horizon.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.45, green: 0.70, blue: 0.95).opacity(0.28),
                                Color(red: 0.75, green: 0.88, blue: 1.0).opacity(0.12),
                                .clear
                            ]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: 0, y: size.height * 0.85)))

                // Small soaring birds drifting at varied heights.
                for i in 0..<birdCount {
                    let baseY = CGFloat(0.10 + haltonValue(index: i + 1, base: 3) * 0.40) * size.height
                    let speed = 25.0 + haltonValue(index: i + 1, base: 5) * 18
                    let phase = haltonValue(index: i + 1, base: 2)
                    let scrollX = (CGFloat(phase) * size.width + CGFloat(t * speed))
                        .truncatingRemainder(dividingBy: size.width + 80) - 40
                    let span: CGFloat = 12
                    let center = CGPoint(x: scrollX, y: baseY)
                    var bird = Path()
                    bird.move(to: CGPoint(x: center.x - span, y: center.y))
                    bird.addQuadCurve(to: CGPoint(x: center.x, y: center.y - 3),
                                      control: CGPoint(x: center.x - span / 2, y: center.y - 5))
                    bird.addQuadCurve(to: CGPoint(x: center.x + span, y: center.y),
                                      control: CGPoint(x: center.x + span / 2, y: center.y - 5))
                    ctx.stroke(bird,
                               with: .color(Color(white: 0.25).opacity(0.65)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - 雲 Cloud

// Owned by KanjiDecoration.view(for:) — registered for the literal 雲.
struct CloudDecoration: View {
    private let cloudCount = 11

    // Densely packed clouds across most of the sheet, each with its own width,
    // y position, speed, AND seed (so the puff arrangement differs cloud-to-
    // cloud — the previous version's identical puff layout made the field look
    // tiled). Halton sequences for position so clouds don't grid up.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<cloudCount {
                    let baseX = CGFloat(haltonValue(index: i + 1, base: 2)) * size.width
                    let baseY = CGFloat(0.08 + haltonValue(index: i + 1, base: 3) * 0.74) * size.height
                    let speed = 2.5 + haltonValue(index: i + 1, base: 5) * 4.5
                    let scrollX = (baseX + CGFloat(t * speed)).truncatingRemainder(dividingBy: size.width + 280) - 140
                    let cloudWidth: CGFloat = 60 + CGFloat(haltonValue(index: i + 1, base: 7)) * 130
                    let alpha = 0.40 + haltonValue(index: i + 1, base: 11) * 0.30
                    drawCloud(ctx: ctx,
                              center: CGPoint(x: scrollX, y: baseY),
                              width: cloudWidth,
                              alpha: alpha,
                              seedSalt: i * 31)
                }
            }
        }
    }
}

// Shared helper — paints a soft cloud at `center` by overlapping circular
// gradient disks. `seedSalt` lets each caller pass a per-cloud salt so the
// puff arrangement varies between clouds (uniform clouds read as a pattern,
// not weather). Reused by sky / cloud / mountain / dream.
func drawCloud(ctx: GraphicsContext, center: CGPoint, width: CGFloat, alpha: Double, seedSalt: Int = 0) {
    let puffCount = 7
    let baseRadius = width / 4
    let color = Color.white
    for puff in 0..<puffCount {
        let p = Double(puff) / Double(puffCount - 1)
        let offsetX = (CGFloat(p) - 0.5) * width
        // Vertical jitter per puff so the cloud underside isn't a smooth arc.
        let yJitter = CGFloat(haltonValue(index: puff + 1 + seedSalt, base: 2) - 0.5) * baseRadius * 0.8
        let offsetY = CGFloat(sin(p * .pi)) * -baseRadius * 0.5 + yJitter
        // Radius jitter per puff so puffs vary in size.
        let radiusJitter = CGFloat(haltonValue(index: puff + 1 + seedSalt, base: 3))
        let puffR = baseRadius * (0.65 + radiusJitter * 0.60)
        let cx = center.x + offsetX
        let cy = center.y + offsetY
        ctx.fill(Path(ellipseIn: CGRect(x: cx - puffR, y: cy - puffR, width: 2 * puffR, height: 2 * puffR)),
                 with: .radialGradient(
                    Gradient(colors: [color.opacity(alpha), .clear]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endRadius: puffR))
    }
}

// MARK: - 虹 Rainbow

// Owned by KanjiDecoration.view(for:) — registered for the literal 虹.
struct RainbowDecoration: View {
    private let colors: [Color] = [
        Color(red: 1.0, green: 0.20, blue: 0.20),
        Color(red: 1.0, green: 0.55, blue: 0.15),
        Color(red: 1.0, green: 0.85, blue: 0.10),
        Color(red: 0.30, green: 0.78, blue: 0.30),
        Color(red: 0.20, green: 0.55, blue: 0.95),
        Color(red: 0.40, green: 0.30, blue: 0.85),
        Color(red: 0.62, green: 0.30, blue: 0.78)
    ]

    // 7 concentric color arcs forming a rainbow arc that spans the sheet,
    // anchored below the bottom edge so only the upper hemisphere shows.
    // Subtle alpha shimmer keeps it alive without distracting.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 1.05  // arc center below the sheet
                let outerR: CGFloat = max(size.width, size.height) * 0.85
                let bandWidth: CGFloat = 6
                let shimmer = 0.85 + 0.15 * sin(t * 0.8)
                for (i, color) in colors.enumerated() {
                    let r = outerR - CGFloat(i) * bandWidth
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                    ring.addEllipse(in: CGRect(x: cx - (r - bandWidth), y: cy - (r - bandWidth),
                                               width: 2 * (r - bandWidth), height: 2 * (r - bandWidth)))
                    ctx.fill(ring, with: .color(color.opacity(0.55 * shimmer)),
                             style: FillStyle(eoFill: true))
                }
            }
        }
    }
}

// MARK: - 嵐 Storm (composite — wind + rain + bolt)

// Owned by KanjiDecoration.view(for:) — registered for the literal 嵐.
struct StormDecoration: View {
    @State private var boltVertices: [CGPoint] = []
    @State private var boltOpacity: Double = 0
    @State private var flashOpacity: Double = 0

    // Storm = wind streaks + dense rain + periodic lightning bolt. Composite
    // of the three weather decorations, layered. Lightning fires more often
    // (every 1.5–3s) than 雷's solo bolts because the storm context calls for it.
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Wind & rain particles via the existing CAEmitterLayer.
                KanjiParticleEmitter(kind: .rain)
                    .allowsHitTesting(false)
                Color(red: 1.0, green: 0.95, blue: 0.55)
                    .opacity(flashOpacity * 0.35)
                    .blendMode(.plusLighter)
                Canvas { ctx, _ in
                    guard !boltVertices.isEmpty else { return }
                    var path = Path()
                    path.move(to: boltVertices[0])
                    for v in boltVertices.dropFirst() { path.addLine(to: v) }
                    ctx.stroke(path,
                               with: .color(Color.white.opacity(boltOpacity * 0.4)),
                               style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                    ctx.stroke(path,
                               with: .color(.white.opacity(boltOpacity)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            .task { await runStorm(in: proxy.size) }
        }
    }

    // Lightning subroutine. Repeats a bolt strike + fade every 1.5–3s.
    private func runStorm(in size: CGSize) async {
        try? await Task.sleep(nanoseconds: 800_000_000)
        while !Task.isCancelled {
            boltVertices = (0...12).map { i in
                let progress = CGFloat(i) / 12
                let baseX = size.width * (0.2 + CGFloat.random(in: 0...0.6))
                let jitter: CGFloat = (i == 0 || i == 12) ? 0 : CGFloat.random(in: -28...28)
                return CGPoint(x: baseX + jitter, y: size.height * progress)
            }
            withAnimation(.easeOut(duration: 0.05)) {
                boltOpacity = 1.0
                flashOpacity = 1.0
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeIn(duration: 0.5)) {
                boltOpacity = 0
                flashOpacity = 0
            }
            let waitNs = UInt64.random(in: 1_500_000_000 ... 3_000_000_000)
            try? await Task.sleep(nanoseconds: waitNs)
        }
    }
}

// MARK: - 草 Grass

// Owned by KanjiDecoration.view(for:) — registered for the literal 草.
struct GrassDecoration: View {
    private let bladeCount = 90

    // Tall grass field — blades now 70–130pt high (was 30–60), denser, with
    // stronger sway, so the field reads as overgrown meadow rather than lawn.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let baseY = size.height
                for i in 0..<bladeCount {
                    let baseX = (CGFloat(i) + 0.5) / CGFloat(bladeCount) * size.width
                    let heightSeed = haltonValue(index: i + 1, base: 2)
                    let phaseSeed = haltonValue(index: i + 1, base: 3) * 6.28
                    let blade: CGFloat = 70 + CGFloat(heightSeed) * 60
                    let sway = CGFloat(sin(t * 1.1 + phaseSeed) * 9)
                    let topX = baseX + sway
                    let topY = baseY - blade
                    var path = Path()
                    path.move(to: CGPoint(x: baseX, y: baseY))
                    path.addQuadCurve(to: CGPoint(x: topX, y: topY),
                                      control: CGPoint(x: (baseX + topX) / 2, y: baseY - blade * 0.5))
                    let toneIndex = i % 3
                    let color: Color
                    switch toneIndex {
                    case 0: color = Color(red: 0.22, green: 0.50, blue: 0.22)
                    case 1: color = Color(red: 0.30, green: 0.60, blue: 0.28)
                    default: color = Color(red: 0.42, green: 0.70, blue: 0.30)
                    }
                    ctx.stroke(path,
                               with: .color(color.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - 石 Stone

// Owned by KanjiDecoration.view(for:) — registered for the literal 石.
struct StoneDecoration: View {
    private let stoneCount = 8

    // Scattered stones along the bottom of the sheet — entirely static (these
    // are stones; they sit there). Stone-grey palette with slight color variation
    // so the pile doesn't read as a single shape.
    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                let baseY = size.height * 0.86
                for i in 0..<stoneCount {
                    let xSeed = kanjiSeedFraction(i, 7)
                    let ySeed = kanjiSeedFraction(i, 11)
                    let sizeSeed = kanjiSeedFraction(i, 17)
                    let x = (0.06 + xSeed * 0.88) * size.width
                    let y = baseY + CGFloat(ySeed - 0.5) * 30
                    let w: CGFloat = 18 + CGFloat(sizeSeed) * 22
                    let h = w * (0.6 + CGFloat(kanjiSeedFraction(i, 23)) * 0.3)
                    let grey = 0.42 + kanjiSeedFraction(i, 29) * 0.15
                    let color = Color(red: grey, green: grey, blue: grey + 0.05)
                    let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
                    // Slight darker base shadow under each stone.
                    let shadowRect = CGRect(x: x - w / 2 + 2, y: y + h / 2 - 2, width: w - 4, height: 4)
                    ctx.fill(Path(ellipseIn: shadowRect),
                             with: .color(Color.black.opacity(0.25)))
                }
            }
        }
    }
}

// MARK: - 田 Rice field

// Owned by KanjiDecoration.view(for:) — registered for the literal 田.
struct RiceFieldDecoration: View {
    private let rows = 4
    private let cols = 6

    // A grid of green rice paddies in the bottom half. Each paddy is a
    // rectangle with subtle wind-ripple animation (alpha shimmer + tiny color
    // shift). The grid structure mirrors the kanji 田's own shape.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let gridTop = size.height * 0.50
                let gridHeight = size.height * 0.45
                let cellWidth = size.width / CGFloat(cols)
                let cellHeight = gridHeight / CGFloat(rows)
                for row in 0..<rows {
                    for col in 0..<cols {
                        let x = CGFloat(col) * cellWidth
                        let y = gridTop + CGFloat(row) * cellHeight
                        let phase = kanjiSeedFraction(row * cols + col, 7) * 6.28
                        let shimmer = 0.7 + 0.3 * sin(t * 1.5 + phase)
                        let baseGreen = 0.55 + 0.10 * sin(t * 0.7 + phase)
                        let color = Color(red: 0.32, green: baseGreen, blue: 0.30)
                        ctx.fill(Path(CGRect(x: x + 2, y: y + 2, width: cellWidth - 4, height: cellHeight - 4)),
                                 with: .color(color.opacity(0.55 * shimmer)))
                    }
                }
                // Grid lines (dividers) — darker stroked overlay.
                let gridColor = Color(red: 0.20, green: 0.30, blue: 0.18).opacity(0.55)
                for row in 0...rows {
                    let y = gridTop + CGFloat(row) * cellHeight
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(line, with: .color(gridColor), lineWidth: 1)
                }
                for col in 0...cols {
                    let x = CGFloat(col) * cellWidth
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: gridTop))
                    line.addLine(to: CGPoint(x: x, y: gridTop + gridHeight))
                    ctx.stroke(line, with: .color(gridColor), lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - 米 Rice grains

// Owned by KanjiDecoration.view(for:) — registered for the literal 米.
struct RiceGrainDecoration: View {
    private let stalkCount = 22

    // Rice paddy — a row of stalks across the bottom, each topped with a
    // drooping cluster of grains (the heavy seed-head a ripe rice plant
    // bends under). Stalks sway in wind. Distinct from 草 (taller, no
    // grain heads) and 田 (the gridded field viewed from above).
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let baseY = size.height
                for i in 0..<stalkCount {
                    let baseX = (CGFloat(i) + 0.5) / CGFloat(stalkCount) * size.width
                    let heightSeed = haltonValue(index: i + 1, base: 2)
                    let phaseSeed = haltonValue(index: i + 1, base: 3) * 6.28
                    let stalkLen: CGFloat = 70 + CGFloat(heightSeed) * 30
                    let sway = CGFloat(sin(t * 1.0 + phaseSeed) * 7)
                    let topX = baseX + sway
                    let topY = baseY - stalkLen
                    // Stalk
                    var stalk = Path()
                    stalk.move(to: CGPoint(x: baseX, y: baseY))
                    stalk.addQuadCurve(to: CGPoint(x: topX, y: topY),
                                       control: CGPoint(x: (baseX + topX) / 2, y: baseY - stalkLen * 0.5))
                    ctx.stroke(stalk,
                               with: .color(Color(red: 0.45, green: 0.62, blue: 0.30).opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    // Drooping grain head — a small cluster of cream-colored
                    // grain ovals fanning down from the stalk tip.
                    for g in 0..<5 {
                        let gAngle = -.pi / 2 + (Double(g) - 2) * 0.18
                        let gOffsetX = CGFloat(cos(gAngle)) * 8
                        let gOffsetY = CGFloat(sin(gAngle)) * 8 + 4   // pull down
                        let gX = topX + gOffsetX
                        let gY = topY + gOffsetY
                        let gW: CGFloat = 3
                        let gH: CGFloat = 6
                        ctx.drawLayer { layer in
                            layer.translateBy(x: gX, y: gY)
                            layer.rotate(by: .radians(Double(gAngle) + .pi / 2))
                            layer.fill(Path(ellipseIn: CGRect(x: -gW / 2, y: -gH / 2, width: gW, height: gH)),
                                       with: .color(Color(red: 0.95, green: 0.88, blue: 0.55).opacity(0.92)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 茶 Tea (steam)

// Owned by KanjiDecoration.view(for:) — registered for the literal 茶.
struct TeaDecoration: View {
    private let steamColumnCount = 24
    private let puffCount = 36

    // Steamy as a fresh cup — many narrow wavy columns rising from the bottom
    // AND a layer of softer rounded puffs drifting up through the air. The
    // previous version had 12 thin lines that read as "ribbons" rather than
    // steam. Doubling the column count + adding rounded puffs gives it body.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Wavy column lines.
                for i in 0..<steamColumnCount {
                    let xBase = (Double(i) + 0.5) / Double(steamColumnCount) * Double(size.width)
                    let amp = 6 + haltonValue(index: i + 1, base: 2) * 8
                    let speed = 0.5 + haltonValue(index: i + 1, base: 3) * 0.5
                    let phase = haltonValue(index: i + 1, base: 5) * 6.28
                    let rise = (t * speed + Double(i) * 0.25).truncatingRemainder(dividingBy: 1.0)
                    let startY = size.height
                    let topY = size.height * 0.10
                    let length = (startY - topY) * CGFloat(rise)
                    var path = Path()
                    var y = startY
                    let xStart = CGFloat(xBase) + CGFloat(amp) * CGFloat(sin(t + phase))
                    path.move(to: CGPoint(x: xStart, y: y))
                    while y > startY - length {
                        y -= 5
                        let x = CGFloat(xBase) + CGFloat(amp) * CGFloat(sin(Double(y) * 0.04 + t + phase))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    let alpha = 0.32 * (1.0 - rise)
                    ctx.stroke(path,
                               with: .color(Color(red: 0.92, green: 0.88, blue: 0.78).opacity(alpha)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }

                // Rounded puffs drifting upward — gives the steam volume.
                for i in 0..<puffCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let xSeed = haltonValue(index: i + 1, base: 3)
                    let rise = (t * 0.4 + phase).truncatingRemainder(dividingBy: 1.0)
                    let baseX = CGFloat(xSeed) * size.width
                    let driftX = CGFloat(sin(t * 0.6 + phase * 6.28)) * 18
                    let x = baseX + driftX
                    let y = size.height - CGFloat(rise) * (size.height * 0.85)
                    let r: CGFloat = 8 + CGFloat(haltonValue(index: i + 1, base: 7)) * 12
                    let alpha = 0.20 * (1.0 - rise)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(
                                Gradient(colors: [
                                    Color(red: 0.95, green: 0.92, blue: 0.84).opacity(alpha),
                                    .clear
                                ]),
                                center: CGPoint(x: x, y: y),
                                startRadius: 0,
                                endRadius: r))
                }
            }
        }
    }
}

// MARK: - 池 Pond (small ripples)

// Owned by KanjiDecoration.view(for:) — registered for the literal 池.
struct PondDecoration: View {
    @State private var drops: [WaterDrop] = []
    private let dropCount = 5

    // Quieter cousin of 水 — fewer, smaller, slower ripples in a pond. Random
    // origins like WaterDecoration but with tighter radii and a single ring
    // per drop, evoking still water disturbed by occasional fall.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let ringWidth: CGFloat = 1.5
                for drop in drops {
                    let center = CGPoint(x: drop.originX * size.width, y: drop.originY * size.height)
                    let prog = ((t / drop.cycleSeconds) + drop.phaseOffset).truncatingRemainder(dividingBy: 1.0)
                    let r = drop.maxRadius * CGFloat(prog)
                    let alpha = 0.50 * pow(1.0 - prog, 1.6)
                    let inner = max(0, r - ringWidth)
                    let outer = r + ringWidth
                    var annulus = Path()
                    annulus.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
                    annulus.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
                    ctx.fill(annulus,
                             with: .color(Color(red: 0.45, green: 0.68, blue: 1.0).opacity(alpha)),
                             style: FillStyle(eoFill: true))
                }
            }
        }
        .onAppear {
            if drops.isEmpty {
                drops = (0..<dropCount).map { _ in
                    WaterDrop(
                        originX: Double.random(in: 0.10...0.90),
                        originY: Double.random(in: 0.18...0.85),
                        phaseOffset: Double.random(in: 0...1),
                        maxRadius: CGFloat.random(in: 35...60),
                        cycleSeconds: Double.random(in: 4.0...6.0)
                    )
                }
            }
        }
    }
}

// MARK: - 泉 Spring (water source)

// Owned by KanjiDecoration.view(for:) — registered for the literal 泉.
struct SpringDecorationSource: View {
    private let jetParticleCount = 45
    private let arcDropletCount = 24

    // Actual fountain spurt — a tall vertical column of water shooting up from
    // a basin at the bottom, then arcing droplets cresting at the top and
    // falling back to either side (the parabolic spray pattern of a real
    // fountain jet). The basin pool ripples gently. Distinct from 水/池
    // ripples and the previous "bubbles drifting up" version.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let sourceX = size.width / 2
                let basinY = size.height * 0.86
                let crestY = size.height * 0.16
                let columnHeight = basinY - crestY

                // Basin water (small pool at the bottom).
                let basinW: CGFloat = 70
                let basinRect = CGRect(x: sourceX - basinW / 2, y: basinY - 6, width: basinW, height: 12)
                ctx.fill(Path(ellipseIn: basinRect),
                         with: .color(Color(red: 0.30, green: 0.55, blue: 0.92).opacity(0.55)))

                // Rising jet — dense column of small fast particles.
                for i in 0..<jetParticleCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let lateral = haltonValue(index: i + 1, base: 3) - 0.5  // -0.5..0.5
                    let rise = (t * 1.4 + phase).truncatingRemainder(dividingBy: 1.0)
                    let y = basinY - CGFloat(rise) * columnHeight
                    let columnSpread: CGFloat = 6  // jet stays narrow
                    let x = sourceX + CGFloat(lateral) * columnSpread
                    let r: CGFloat = 2.0
                    let alpha = 0.85 * (1.0 - pow(rise, 1.3))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Color(red: 0.65, green: 0.85, blue: 1.0).opacity(alpha)))
                }

                // Arc droplets — particles that crest at the top and fall to
                // either side in a parabola, the classic fountain spray.
                for i in 0..<arcDropletCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let direction: CGFloat = haltonValue(index: i + 1, base: 3) > 0.5 ? 1 : -1
                    let cycle: Double = 2.4
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)
                    // Parabola: y = -4·prog·(1−prog) gives a peak at prog=0.5.
                    let arcHeight = 4 * prog * (1.0 - prog)
                    let xOffset = CGFloat(prog) * 90 * direction
                    let y = crestY - CGFloat(arcHeight) * 30 + CGFloat(prog) * columnHeight * 0.85
                    let x = sourceX + xOffset
                    let r: CGFloat = 2.2
                    let alpha = 0.80 * sin(prog * .pi)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Color(red: 0.70, green: 0.88, blue: 1.0).opacity(alpha)))
                }
            }
        }
    }
}

// MARK: - 林 Woods (2 trees)

// Owned by KanjiDecoration.view(for:) — registered for the literal 林.
struct WoodsDecoration: View {
    private let canopyBlobCount = 28

    // Two narrower canopies side-by-side (matching the kanji 林's two-tree
    // composition), each with its own trunk. Sway animation per canopy is on
    // a different sine phase so the two trees breathe out of sync.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawSubTree(ctx: ctx, size: size, t: t, centerX: size.width * 0.30, swayPhase: 0.0)
                drawSubTree(ctx: ctx, size: size, t: t, centerX: size.width * 0.70, swayPhase: 2.4)
            }
        }
    }

    // Renders one tree (trunk + canopy) anchored at centerX. Used by both 林 and 森.
    private func drawSubTree(ctx: GraphicsContext, size: CGSize, t: Double, centerX: CGFloat, swayPhase: Double) {
        let trunkWidth: CGFloat = 16
        let canopyJoinY = size.height * 0.40
        let trunkRect = CGRect(x: centerX - trunkWidth / 2, y: canopyJoinY, width: trunkWidth, height: size.height - canopyJoinY)
        ctx.fill(Path(roundedRect: trunkRect, cornerRadius: 3),
                 with: .color(Color(red: 0.30, green: 0.20, blue: 0.12).opacity(0.85)))

        let sway = CGFloat(sin(t * 0.7 + swayPhase) * 4)
        let canopyTop = size.height * 0.08
        let canopyBottom = size.height * 0.46
        for i in 0..<canopyBlobCount {
            let xFrac = kanjiSeedFraction(i, 7) - 0.5
            let yFrac = kanjiSeedFraction(i, 11)
            let radius: CGFloat = 18 + CGFloat(kanjiSeedFraction(i, 13)) * 22
            let cx = centerX + CGFloat(xFrac) * 110 + sway
            let cy = canopyTop + CGFloat(yFrac) * (canopyBottom - canopyTop)
            let color = i % 2 == 0
                ? Color(red: 0.18, green: 0.46, blue: 0.22)
                : Color(red: 0.28, green: 0.58, blue: 0.28)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(color.opacity(0.72)))
        }
    }
}

// MARK: - 森 Forest (3 trees)

// Owned by KanjiDecoration.view(for:) — registered for the literal 森.
struct ForestDecoration: View {
    private let canopyBlobCount = 22

    // Three trees in a triangle, denser than 林. Two side trees at the bottom
    // row + one taller tree behind them, matching the kanji 森's three-tree
    // composition (one on top, two below).
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawSubTree(ctx: ctx, size: size, t: t, centerX: size.width * 0.50, scale: 1.15, swayPhase: 0.0, anchorY: size.height * 0.38)
                drawSubTree(ctx: ctx, size: size, t: t, centerX: size.width * 0.20, scale: 0.85, swayPhase: 1.8, anchorY: size.height * 0.50)
                drawSubTree(ctx: ctx, size: size, t: t, centerX: size.width * 0.80, scale: 0.85, swayPhase: 3.4, anchorY: size.height * 0.50)
            }
        }
    }

    // Same engine as WoodsDecoration's subtree but with scale + anchorY for
    // staggered positioning.
    private func drawSubTree(ctx: GraphicsContext, size: CGSize, t: Double, centerX: CGFloat, scale: CGFloat, swayPhase: Double, anchorY: CGFloat) {
        let trunkWidth: CGFloat = 14 * scale
        let trunkRect = CGRect(x: centerX - trunkWidth / 2, y: anchorY, width: trunkWidth, height: size.height - anchorY)
        ctx.fill(Path(roundedRect: trunkRect, cornerRadius: 3),
                 with: .color(Color(red: 0.30, green: 0.20, blue: 0.12).opacity(0.85)))

        let sway = CGFloat(sin(t * 0.7 + swayPhase) * 4)
        let canopyHeight = anchorY
        for i in 0..<canopyBlobCount {
            let xFrac = kanjiSeedFraction(i, 7) - 0.5
            let yFrac = kanjiSeedFraction(i, 11)
            let radius: CGFloat = (18 + CGFloat(kanjiSeedFraction(i, 13)) * 20) * scale
            let cx = centerX + CGFloat(xFrac) * 100 * scale + sway
            let cy = CGFloat(yFrac) * canopyHeight
            let color = i % 2 == 0
                ? Color(red: 0.18, green: 0.46, blue: 0.22)
                : Color(red: 0.28, green: 0.58, blue: 0.28)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(color.opacity(0.72)))
        }
    }
}

// MARK: - 葉 Leaf (single-color leaf drift)

// Owned by KanjiDecoration.view(for:) — registered for the literal 葉.
// A single drifting leaf's randomized parameters — generated once at view
// appearance via Random() so positions, fall speeds, sway frequencies, and
// rotation rates are genuinely chaotic rather than evenly-distributed Halton
// samples (the previous version had every leaf on the same slow rhythm).
struct LeafState: Equatable {
    let startX: Double          // 0–1 horizontal start position
    let fallDuration: Double    // seconds top-to-bottom
    let swayAmplitude: Double   // horizontal sway in pt
    let swayFrequency: Double   // sway oscillation rate
    let rotationRate: Double    // rotation speed
    let initialPhase: Double    // 0–1 offset into the fall cycle
    let size: Double            // leaf scale multiplier
    let tone: Int               // palette index 0/1/2
}

// Owned by KanjiDecoration.view(for:) — registered for the literal 葉.
struct LeafDecoration: View {
    private let leafCount = 20
    @State private var leaves: [LeafState] = []

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for leaf in leaves {
                    let prog = ((t / leaf.fallDuration) + leaf.initialPhase).truncatingRemainder(dividingBy: 1.0)
                    let sway = sin(t * leaf.swayFrequency + leaf.initialPhase * 12.56) * leaf.swayAmplitude
                    let x = CGFloat(leaf.startX) * size.width + CGFloat(sway)
                    let y = -20 + (size.height + 40) * CGFloat(prog)
                    let rotation = sin(t * leaf.rotationRate + leaf.initialPhase * 8) * 1.4
                    let color: Color
                    switch leaf.tone {
                    case 0: color = Color(red: 0.28, green: 0.62, blue: 0.32)
                    case 1: color = Color(red: 0.40, green: 0.72, blue: 0.35)
                    default: color = Color(red: 0.55, green: 0.78, blue: 0.42)
                    }
                    let leafSize: CGFloat = CGFloat(12 * leaf.size)
                    ctx.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(rotation))
                        let rect = CGRect(x: -leafSize / 2, y: -leafSize * 0.7, width: leafSize, height: leafSize * 1.4)
                        layer.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.82)))
                    }
                }
            }
        }
        .onAppear {
            if leaves.isEmpty {
                leaves = (0..<leafCount).map { i in
                    LeafState(
                        startX: Double.random(in: 0...1),
                        fallDuration: Double.random(in: 6.5...11.0),
                        swayAmplitude: Double.random(in: 12...40),
                        swayFrequency: Double.random(in: 0.6...1.4),
                        rotationRate: Double.random(in: 0.9...2.0),
                        initialPhase: Double.random(in: 0...1),
                        size: Double.random(in: 0.7...1.3),
                        tone: i % 3
                    )
                }
            }
        }
    }
}
