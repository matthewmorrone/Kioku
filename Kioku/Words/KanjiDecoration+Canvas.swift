import SwiftUI

// SwiftUI Canvas-based decorations — for effects where geometric/scripted
// animation is the right tool rather than CAEmitterLayer particles: bolts, rays,
// pulses, waves, sweeps. Each view fills its parent (call site sizes it via
// .frame and clips it). All run via TimelineView(.animation) so motion ticks at
// display refresh rate without manual timers.

// MARK: - 水 Water

// Single rain-drop hit on a still water surface — origin position + ripple
// timing + max radius all generated fresh per drop so the pattern never reads
// as a grid.
struct WaterDrop: Equatable {
    let originX: Double         // 0–1 fraction of width
    let originY: Double         // 0–1 fraction of height
    let phaseOffset: Double     // 0–1 — staggers this drop's cycle vs others
    let maxRadius: CGFloat
    let cycleSeconds: Double
}

// Owned by KanjiDecoration.view(for:) — registered for the literal 水.
struct WaterDecoration: View {
    @State private var drops: [WaterDrop] = []
    private let dropCount = 9

    // Multiple drop points scattered across the full sheet (not just the lower
    // half), each emitting concentric ripples on its own phase + radius + cycle.
    // The drop parameters are generated ONCE on appear via Random() — the previous
    // deterministic seedFraction version laid out drops on a hidden grid because
    // the hash collision space is small; true randomness scatters more naturally.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let ringsPerOrigin = 3
                let ringWidth: CGFloat = 2.2
                for drop in drops {
                    let center = CGPoint(x: drop.originX * size.width, y: drop.originY * size.height)
                    for ring in 0..<ringsPerOrigin {
                        let ringPhase = Double(ring) / Double(ringsPerOrigin)
                        let prog = ((t / drop.cycleSeconds) + drop.phaseOffset + ringPhase).truncatingRemainder(dividingBy: 1.0)
                        let r = drop.maxRadius * CGFloat(prog)
                        let alpha = 0.55 * pow(1.0 - prog, 1.6)
                        let inner = max(0, r - ringWidth)
                        let outer = r + ringWidth
                        var annulus = Path()
                        annulus.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
                        annulus.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
                        ctx.fill(annulus,
                                 with: .color(Color(red: 0.45, green: 0.68, blue: 1.0).opacity(alpha)),
                                 style: FillStyle(eoFill: true))
                    }
                    let dotR: CGFloat = 1.6
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: 2 * dotR, height: 2 * dotR)),
                             with: .color(Color(red: 0.45, green: 0.68, blue: 1.0).opacity(0.35)))
                }
            }
        }
        .onAppear {
            if drops.isEmpty {
                drops = (0..<dropCount).map { _ in
                    WaterDrop(
                        originX: Double.random(in: 0.06...0.94),
                        originY: Double.random(in: 0.10...0.92),
                        phaseOffset: Double.random(in: 0...1),
                        maxRadius: CGFloat.random(in: 60...140),
                        cycleSeconds: Double.random(in: 2.6...4.4)
                    )
                }
            }
        }
    }
}

// MARK: - 日 Sun

// Owned by KanjiDecoration.view(for:) — registered for the literal 日.
struct SunDecoration: View {
    private let rayCount = 18

    // Long triangular rays radiating from a warm core in the top-right corner,
    // slowly rotating around the source. Each ray is a triangle filled with a
    // yellow→clear gradient so the source feels bright and the tip dissolves into
    // the background. A radial glow disk behind the rays gives the corner a
    // proper sense of light source.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width * 0.9
                let cy = size.height * 0.08
                let glowR = max(size.width, size.height) * 0.55
                let glowRect = CGRect(x: cx - glowR, y: cy - glowR, width: 2 * glowR, height: 2 * glowR)
                ctx.fill(Path(ellipseIn: glowRect),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.92, blue: 0.55).opacity(0.45),
                                Color(red: 1.0, green: 0.75, blue: 0.30).opacity(0.10),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: glowR))

                let rayLen = max(size.width, size.height) * 1.1
                let rotation = t * 0.06
                for i in 0..<rayCount {
                    let angle = (Double(i) / Double(rayCount)) * 2 * .pi + rotation
                    let half: Double = 0.045
                    let p1 = CGPoint(x: cx, y: cy)
                    let p2 = CGPoint(x: cx + CGFloat(cos(angle - half)) * rayLen,
                                     y: cy + CGFloat(sin(angle - half)) * rayLen)
                    let p3 = CGPoint(x: cx + CGFloat(cos(angle + half)) * rayLen,
                                     y: cy + CGFloat(sin(angle + half)) * rayLen)
                    var ray = Path()
                    ray.move(to: p1)
                    ray.addLine(to: p2)
                    ray.addLine(to: p3)
                    ray.closeSubpath()
                    let midX = (p2.x + p3.x) / 2
                    let midY = (p2.y + p3.y) / 2
                    ctx.fill(ray,
                             with: .linearGradient(
                                Gradient(colors: [
                                    Color(red: 1.0, green: 0.9, blue: 0.4).opacity(0.55),
                                    .clear
                                ]),
                                startPoint: p1,
                                endPoint: CGPoint(x: midX, y: midY)))
                }
            }
        }
    }
}

// MARK: - 月 Moon

// Owned by KanjiDecoration.view(for:) — registered for the literal 月.
struct MoonDecoration: View {
    private let starCount = 32

    // Crescent moon over a starry sky. The crescent is built by drawing inside a
    // clipped layer: clip OUTSIDE the inner ellipse, then fill the outer ellipse —
    // only the part of the outer that's outside the inner survives, giving one
    // clean crescent. The previous even-odd-fill version rendered a double-crescent
    // because the offset inner ellipse extended beyond the outer's bounds on the
    // far side, and the eoFill rule filled THAT region too.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width * 0.78
                let cy = size.height * 0.22
                let moonR: CGFloat = min(size.width, size.height) * 0.18
                let outerRect = CGRect(x: cx - moonR, y: cy - moonR, width: 2 * moonR, height: 2 * moonR)
                let innerOffsetX = moonR * 0.42
                let innerRect = CGRect(x: cx - moonR + innerOffsetX, y: cy - moonR, width: 2 * moonR, height: 2 * moonR)

                // Halo first so it sits behind the crescent.
                let haloR = moonR * 2.0
                ctx.fill(Path(ellipseIn: CGRect(x: cx - haloR, y: cy - haloR, width: 2 * haloR, height: 2 * haloR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 0.95, green: 0.95, blue: 0.85).opacity(0.22),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: haloR))

                // Crescent via inverse-clip: keep only what's OUTSIDE innerRect, then fill outer.
                ctx.drawLayer { layer in
                    layer.clip(to: Path(ellipseIn: innerRect), options: .inverse)
                    layer.fill(Path(ellipseIn: outerRect),
                               with: .color(Color(red: 0.97, green: 0.94, blue: 0.80).opacity(0.92)))
                }

                // Twinkling background stars.
                for i in 0..<starCount {
                    let x = CGFloat(kanjiSeedFraction(i, 41)) * size.width
                    let y = CGFloat(kanjiSeedFraction(i, 47)) * size.height * 0.7
                    let phase = kanjiSeedFraction(i, 53) * 2 * .pi
                    let twinkle = 0.3 + 0.7 * abs(sin(t * 1.1 + phase))
                    let r: CGFloat = 0.7 + CGFloat(kanjiSeedFraction(i, 59)) * 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(.white.opacity(twinkle * 0.6)))
                }
            }
        }
    }
}

// MARK: - 星 Stars

// Owned by KanjiDecoration.view(for:) — registered for the literal 星.
struct StarDecoration: View {
    private let pointCount = 180

    // Dense night sky — ~180 stars scattered across the sheet. Most are quiet
    // pinpricks so the field reads as STARS, not a christmas-tree light show; a
    // smaller subset (every 8th) gets a 4-point sparkle cross to add highlights.
    // Subtle twinkle keeps the field alive without distracting.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<pointCount {
                    let x = CGFloat(kanjiSeedFraction(i, 3)) * size.width
                    let y = CGFloat(kanjiSeedFraction(i, 7)) * size.height
                    let sizeBucket = i % 12
                    let baseRadius: CGFloat = sizeBucket == 0 ? 2.4 : (sizeBucket < 3 ? 1.6 : 0.9)
                    let phase = kanjiSeedFraction(i, 11) * 2 * .pi
                    let twinkle = 0.5 + 0.5 * sin(t * 0.7 + phase)
                    let alpha = (0.55 + 0.45 * twinkle) * (sizeBucket == 0 ? 1.0 : 0.8)
                    let r = baseRadius
                    let coreRect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: coreRect), with: .color(.white.opacity(alpha)))

                    // Every 8th star gets a sparkle cross for the brightest pinpoints.
                    if i % 8 == 0 {
                        let sparkleR = r * 3.5
                        var sparkle = Path()
                        sparkle.move(to: CGPoint(x: x - sparkleR, y: y))
                        sparkle.addLine(to: CGPoint(x: x + sparkleR, y: y))
                        sparkle.move(to: CGPoint(x: x, y: y - sparkleR))
                        sparkle.addLine(to: CGPoint(x: x, y: y + sparkleR))
                        ctx.stroke(sparkle, with: .color(.white.opacity(alpha * 0.5)), lineWidth: 0.7)
                    }
                }
            }
        }
    }
}

// MARK: - 雷 Lightning

// One lightning bolt + its branches, captured per strike so each strike can have
// fresh randomized geometry. Polyline + branches stay as plain arrays of CGPoint
// because Path is value-typed but isn't @State-friendly across observable updates.
struct LightningBolt: Equatable {
    var main: [CGPoint]
    var branches: [[CGPoint]]
}

// Owned by KanjiDecoration.view(for:) — registered for the literal 雷.
struct LightningDecoration: View {
    @State private var bolts: [LightningBolt] = []
    @State private var flashOpacity: Double = 0
    @State private var boltOpacity: Double = 0

    // Real lightning every 2–5 seconds. Each strike spawns 1–2 bolts (each with
    // its own jagged path + 1–2 forking branches), drawn against a screen-wide
    // flash. The bolt is rendered in two passes — wide soft halo first, narrow
    // bright core on top — so the bolt has the haloed-glow look of real lightning
    // rather than a flat polyline. Branches are shorter than the main bolt and
    // taper off mid-page.
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.95, green: 0.95, blue: 1.0)
                    .opacity(flashOpacity * 0.50)
                    .blendMode(.plusLighter)

                Canvas { ctx, _ in
                    for bolt in bolts {
                        drawBolt(bolt.main, in: ctx)
                        for branch in bolt.branches {
                            drawBolt(branch, in: ctx, widthScale: 0.6, alphaScale: 0.75)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .task { await runStrikeLoop(in: proxy.size) }
        }
    }

    // Strokes a bolt polyline THREE times — wide soft halo, medium glow, and a
    // bright narrow core — so the bolt reads as electric light surrounded by
    // atmosphere rather than a single drawn line. Heavier than the previous
    // two-pass version because the bolt wasn't reading prominently enough.
    private func drawBolt(_ points: [CGPoint], in ctx: GraphicsContext, widthScale: CGFloat = 1.0, alphaScale: Double = 1.0) {
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        // Outer halo — wide, low alpha, blue-tinted for the electric look.
        ctx.stroke(path,
                   with: .color(Color(red: 0.7, green: 0.85, blue: 1.0).opacity(boltOpacity * 0.55 * alphaScale)),
                   style: StrokeStyle(lineWidth: 22 * widthScale, lineCap: .round, lineJoin: .round))
        // Mid glow — narrower, brighter.
        ctx.stroke(path,
                   with: .color(Color.white.opacity(boltOpacity * 0.85 * alphaScale)),
                   style: StrokeStyle(lineWidth: 8 * widthScale, lineCap: .round, lineJoin: .round))
        // Core — narrow, fully opaque white. This is the bolt itself.
        ctx.stroke(path,
                   with: .color(Color.white.opacity(boltOpacity * alphaScale)),
                   style: StrokeStyle(lineWidth: 2.5 * widthScale, lineCap: .round, lineJoin: .round))
    }

    // Loops indefinitely. First strike fires ~600ms after appear so the user sees
    // lightning almost immediately on opening the kanji page (the previous 2–5s
    // initial wait left people staring at a dead-quiet sheet and gave the impression
    // there was no bolt at all). Subsequent strikes happen every 1.5–3.5s.
    private func runStrikeLoop(in size: CGSize) async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        var firstStrike = true
        while !Task.isCancelled {
            if firstStrike == false {
                let waitNs = UInt64.random(in: 1_500_000_000 ... 3_500_000_000)
                try? await Task.sleep(nanoseconds: waitNs)
            }
            firstStrike = false
            if Task.isCancelled { return }
            let boltCount = Int.random(in: 2...3)
            bolts = (0..<boltCount).map { _ in generateBolt(in: size) }
            withAnimation(.easeOut(duration: 0.05)) {
                flashOpacity = 1.0
                boltOpacity = 1.0
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeIn(duration: 0.7)) {
                flashOpacity = 0
                boltOpacity = 0
            }
        }
    }

    // Builds a top→bottom jagged polyline with ~14 vertices, then attaches 1–2
    // shorter forked branches that peel off mid-bolt and end before reaching the
    // bottom. Each strike re-rolls so bolts are visibly different each time.
    private func generateBolt(in size: CGSize) -> LightningBolt {
        let vertexCount = 14
        let startX = size.width * CGFloat.random(in: 0.15 ... 0.85)
        let endX = startX + size.width * CGFloat.random(in: -0.25 ... 0.25)
        var main: [CGPoint] = []
        for i in 0...vertexCount {
            let progress = CGFloat(i) / CGFloat(vertexCount)
            let baseX = startX + (endX - startX) * progress
            let jitter: CGFloat = (i == 0 || i == vertexCount) ? 0 : CGFloat.random(in: -28 ... 28)
            main.append(CGPoint(x: baseX + jitter, y: size.height * progress))
        }

        // Branches: pick 1–2 vertices in the middle third of the bolt and grow
        // 4–7-vertex branches that fan off to one side.
        var branches: [[CGPoint]] = []
        let branchCount = Int.random(in: 1...2)
        for _ in 0..<branchCount {
            let originIndex = Int.random(in: 3 ... (vertexCount - 4))
            let origin = main[originIndex]
            let direction: CGFloat = Bool.random() ? 1 : -1
            let branchLen = Int.random(in: 4 ... 7)
            var branch: [CGPoint] = [origin]
            var x = origin.x
            var y = origin.y
            for _ in 0..<branchLen {
                x += direction * CGFloat.random(in: 12 ... 30)
                y += CGFloat.random(in: 18 ... 36)
                if y > size.height { break }
                branch.append(CGPoint(x: x, y: y))
            }
            branches.append(branch)
        }
        return LightningBolt(main: main, branches: branches)
    }
}

// MARK: - 風 Wind

// Owned by KanjiDecoration.view(for:) — registered for the literal 風.
struct WindDecoration: View {
    private let lineCount = 36

    // Pure horizontal speed lines scrolling left → right at varied lengths and
    // speeds — the design previously used for 走 (run). The user said the run
    // animation reads more like wind, so we adopted it here. Simpler than the
    // previous curved-bezier-streaks + dust composition; reads more directly
    // as "wind moving across."
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<lineCount {
                    let lane = haltonValue(index: i + 1, base: 2)
                    let phase = haltonValue(index: i + 1, base: 3)
                    let speedJitter = haltonValue(index: i + 1, base: 5)
                    let cycle = 0.7 + speedJitter * 1.2
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)
                    let lineLen: CGFloat = size.width * CGFloat(0.18 + speedJitter * 0.35)
                    let startX = -lineLen + (size.width + 2 * lineLen) * CGFloat(prog)
                    let y = (0.08 + lane * 0.84) * size.height
                    var line = Path()
                    line.move(to: CGPoint(x: startX, y: y))
                    line.addLine(to: CGPoint(x: startX + lineLen, y: y))
                    let alpha = 0.45 * sin(prog * .pi)
                    let lineWidth: CGFloat = 0.8 + CGFloat(speedJitter) * 1.5
                    ctx.stroke(line,
                               with: .color(Color(white: 0.95).opacity(alpha)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
        }
    }
}

// Owned by KanjiDecoration.view(for:) — registered for the literal 風 (legacy
// curved-streaks design preserved here in case we want to A/B it). Currently
// unused; the active 風 is WindDecoration above.
struct WindCurvedStreaksDecoration: View {
    private let streakCount = 38
    private let dustCount = 36

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Streaks.
                for i in 0..<streakCount {
                    let ySeed = kanjiSeedFraction(i, 17)
                    let phase = kanjiSeedFraction(i, 29)
                    let dirSeed = kanjiSeedFraction(i, 37)
                    let lengthSeed = kanjiSeedFraction(i, 43)
                    let speedSeed = kanjiSeedFraction(i, 49)
                    let cycle = 1.0 + speedSeed * 1.6
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)

                    let streakLen: CGFloat = size.width * CGFloat(0.18 + lengthSeed * 0.55)
                    let startX = -streakLen + (size.width + 2 * streakLen) * CGFloat(prog)
                    let endX = startX + streakLen
                    let baseY = CGFloat(ySeed) * size.height
                    let curveSign: CGFloat = dirSeed > 0.5 ? 1 : -1
                    let controlY = baseY + curveSign * CGFloat(10 + lengthSeed * 22)

                    var path = Path()
                    path.move(to: CGPoint(x: startX, y: baseY))
                    path.addQuadCurve(to: CGPoint(x: endX, y: baseY - 4),
                                      control: CGPoint(x: (startX + endX) / 2, y: controlY))

                    let edgeFade = sin(prog * .pi)
                    let alpha = (0.40 + 0.25 * (1.0 - speedSeed)) * edgeFade
                    let lineWidth: CGFloat = 1.0 + CGFloat(lengthSeed) * 1.8
                    ctx.stroke(path,
                               with: .color(Color(white: 0.95).opacity(alpha)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                // Dust particles — small dots scrolling fast across the air.
                for i in 0..<dustCount {
                    let ySeed = kanjiSeedFraction(i, 61)
                    let phase = kanjiSeedFraction(i, 67)
                    let speedSeed = kanjiSeedFraction(i, 73)
                    let cycle = 1.0 + speedSeed * 0.8
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)
                    let x = -20 + (size.width + 40) * CGFloat(prog)
                    let y = CGFloat(ySeed) * size.height + CGFloat(sin(t * 2.0 + phase * 6.28)) * 5
                    let r: CGFloat = 1.0 + CGFloat(kanjiSeedFraction(i, 71)) * 1.0
                    let alpha = 0.55 * sin(prog * .pi)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Color(white: 0.92).opacity(alpha)))
                }
            }
        }
    }
}

// MARK: - 木 Tree

// Owned by KanjiDecoration.view(for:) — registered for the literal 木.
struct TreeDecoration: View {
    private let canopyBlobCount = 40
    private let fallingLeafCount = 8

    // View from underneath the tree: a wide canopy spans the entire TOP of the
    // card (full width), and a single dark trunk runs the right edge from the
    // canopy down to the bottom. The canopy's bottom edge is irregular — many
    // overlapping leaf-cluster blobs of varying sizes — so the underside reads
    // as a foliage ceiling rather than a flat band. A few darker shadow blobs
    // sit beneath the main canopy for depth, and occasional leaves drift down
    // through the open space below.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawTrunk(ctx: ctx, size: size)
                drawCanopy(ctx: ctx, size: size, t: t)
                drawFallingLeaves(ctx: ctx, size: size, t: t)
            }
        }
    }

    // Trunk: a vertical dark-brown bar running the right edge of the card from
    // the canopy down to the bottom. Slight rightward bias so it's flush with
    // the edge — the canopy hides where it joins.
    private func drawTrunk(ctx: GraphicsContext, size: CGSize) {
        let trunkWidth: CGFloat = 30
        let rightEdge = size.width - 2
        let trunkX = rightEdge - trunkWidth
        let canopyJoinY = size.height * 0.30
        let trunkRect = CGRect(x: trunkX, y: canopyJoinY, width: trunkWidth, height: size.height - canopyJoinY)
        ctx.fill(Path(roundedRect: trunkRect, cornerRadius: 4),
                 with: .color(Color(red: 0.30, green: 0.20, blue: 0.12).opacity(0.85)))
    }

    // Canopy: many overlapping circles densely packed across the top of the card
    // with vertical jitter on the bottom-most blobs to produce an irregular leaf
    // edge. Two-tone green (alternating per blob) gives the foliage internal
    // variation. The whole mass sways together on a slow sine so the wind reads
    // as moving the tree rather than moving individual leaves.
    private func drawCanopy(ctx: GraphicsContext, size: CGSize, t: Double) {
        let canopyHeight = size.height * 0.45
        let sway = CGFloat(sin(t * 0.7) * 5)

        // Darker shadow band sitting just under the main canopy for depth.
        let shadowRect = CGRect(x: 0, y: canopyHeight - 16, width: size.width, height: 18)
        ctx.fill(Path(shadowRect),
                 with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.10, green: 0.32, blue: 0.16).opacity(0.0),
                        Color(red: 0.10, green: 0.32, blue: 0.16).opacity(0.35)
                    ]),
                    startPoint: CGPoint(x: 0, y: shadowRect.minY),
                    endPoint: CGPoint(x: 0, y: shadowRect.maxY)))

        for i in 0..<canopyBlobCount {
            // Distribute blobs across the full width with random clustering.
            let xFraction = kanjiSeedFraction(i, 7)
            let yFraction = kanjiSeedFraction(i, 11)
            let radius: CGFloat = 26 + CGFloat(kanjiSeedFraction(i, 13)) * 30

            // Blobs near the bottom of the canopy band get more vertical jitter
            // so the underside edge is uneven; blobs near the top stay close to
            // the card edge so the canopy is thickly capped.
            let baseY = canopyHeight * CGFloat(yFraction)
            let bottomBias = pow(yFraction, 1.5)  // bottom blobs spread more
            let yJitter = CGFloat(kanjiSeedFraction(i, 17) - 0.5) * 20 * CGFloat(bottomBias)
            let cx = CGFloat(xFraction) * size.width + sway
            let cy = baseY + yJitter

            let alpha = 0.65 + kanjiSeedFraction(i, 19) * 0.20
            let color = i % 2 == 0
                ? Color(red: 0.18, green: 0.46, blue: 0.22)
                : Color(red: 0.28, green: 0.58, blue: 0.28)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: 2 * radius, height: 2 * radius)),
                     with: .color(color.opacity(alpha)))
        }
    }

    // A few small leaves drifting down from the canopy across the open space
    // below. Each leaf has its own fall phase and lateral oscillation so the
    // group never looks like a parade.
    private func drawFallingLeaves(ctx: GraphicsContext, size: CGSize, t: Double) {
        let fallDuration: Double = 7.0
        for i in 0..<fallingLeafCount {
            let phase = kanjiSeedFraction(i, 23)
            let prog = ((t / fallDuration) + phase).truncatingRemainder(dividingBy: 1.0)
            let startX = (0.10 + kanjiSeedFraction(i, 29) * 0.70) * size.width
            let sway = CGFloat(sin(t * 1.2 + phase * 6) * 16)
            let x = CGFloat(startX) + sway
            let y = size.height * CGFloat(0.40 + 0.55 * prog)
            let leafLen: CGFloat = 9
            let leafWidth: CGFloat = leafLen * 0.55
            let rotation = sin(t * 1.5 + phase * 4) * 0.8
            let color = i % 2 == 0
                ? Color(red: 0.45, green: 0.70, blue: 0.32)
                : Color(red: 0.68, green: 0.78, blue: 0.32)

            ctx.drawLayer { layer in
                layer.translateBy(x: x, y: y)
                layer.rotate(by: .radians(rotation))
                let leafRect = CGRect(x: -leafWidth / 2, y: -leafLen / 2, width: leafWidth, height: leafLen)
                layer.fill(Path(ellipseIn: leafRect), with: .color(color.opacity(0.75)))
            }
        }
    }
}

// MARK: - 花 Flower (meadow)

// Owned by KanjiDecoration.view(for:) — registered for the literal 花.
struct FlowerDecoration: View {
    private let flowerCount = 9

    // A meadow of small flowers across the bottom of the sheet. Each flower has
    // a green stem, a 5-petal head, and a golden center; colors cycle through a
    // small palette so the meadow reads varied. Always rendered at full size —
    // the previous `@State bloom` animation was leaving the page empty because
    // SwiftUI's `withAnimation` doesn't interpolate plain @State Doubles that
    // are read inside a Canvas closure (it animates view-property reads, not
    // arbitrary state references), so bloom stayed visually 0 the whole time.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<flowerCount {
                    let xSeed = kanjiSeedFraction(i, 7)
                    let heightSeed = kanjiSeedFraction(i, 11)
                    let phaseSeed = kanjiSeedFraction(i, 13)
                    let colorIndex = i % 5
                    let baseX = (0.05 + xSeed * 0.90) * size.width
                    let stemLen: CGFloat = 50 + heightSeed * 50
                    let baseY = size.height * 0.95
                    let topY = baseY - stemLen
                    let sway = CGFloat(sin(t * 1.2 + phaseSeed * 6.28) * 3)
                    let headX = baseX + sway

                    var stem = Path()
                    stem.move(to: CGPoint(x: baseX, y: baseY))
                    stem.addQuadCurve(to: CGPoint(x: headX, y: topY),
                                      control: CGPoint(x: (baseX + headX) / 2, y: (baseY + topY) / 2))
                    ctx.stroke(stem,
                               with: .color(Color(red: 0.32, green: 0.58, blue: 0.28).opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

                    let petalLen: CGFloat = 10
                    let petalWidth: CGFloat = 7
                    let petalColor = flowerColor(colorIndex)
                    for petal in 0..<5 {
                        let angle = (Double(petal) / 5) * 2 * .pi
                        let px = headX + CGFloat(cos(angle)) * petalLen * 0.55
                        let py = topY + CGFloat(sin(angle)) * petalLen * 0.55
                        ctx.drawLayer { layer in
                            layer.translateBy(x: px, y: py)
                            layer.rotate(by: .radians(angle + .pi / 2))
                            let rect = CGRect(x: -petalWidth / 2, y: -petalLen / 2, width: petalWidth, height: petalLen)
                            layer.fill(Path(ellipseIn: rect), with: .color(petalColor.opacity(0.80)))
                        }
                    }
                    let centerR: CGFloat = 3
                    ctx.fill(Path(ellipseIn: CGRect(x: headX - centerR, y: topY - centerR, width: 2 * centerR, height: 2 * centerR)),
                             with: .color(Color(red: 0.95, green: 0.78, blue: 0.25).opacity(0.95)))
                }
            }
        }
    }

    // Palette for the meadow — five soft floral tones cycled in flowerCount order.
    private func flowerColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 1.0, green: 0.62, blue: 0.78)   // pink
        case 1: return Color(red: 1.0, green: 0.92, blue: 0.45)   // yellow
        case 2: return Color(red: 0.95, green: 0.95, blue: 0.96)  // white
        case 3: return Color(red: 0.78, green: 0.62, blue: 0.95)  // lavender
        default: return Color(red: 0.95, green: 0.52, blue: 0.42) // coral
        }
    }
}

// MARK: - 心 Heart

// Owned by KanjiDecoration.view(for:) — registered for the literal 心.
struct HeartDecoration: View {
    private let cycleSeconds: Double = 1.6

    // Lub-DUB heartbeat rhythm — two distinct pulses per cycle (the first is the
    // shorter S1 sound, the second is the louder S2 a fraction of a second later),
    // then a long quiet period before the next cycle starts. Each pulse drives
    // an outer cream halo + an inner gold core; the second pulse is slightly
    // stronger so the rhythm reads as lub-DUB rather than two equal beats.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                let baseR = min(size.width, size.height) * 0.6

                let cyclePhase = (t / cycleSeconds).truncatingRemainder(dividingBy: 1.0)
                let lub = max(0, exp(-pow((cyclePhase - 0.0) * 30, 2)))
                let dub = max(0, exp(-pow((cyclePhase - 0.20) * 22, 2))) * 1.25
                let beat = min(1.0, lub + dub)

                let r1 = baseR * CGFloat(0.95 + 0.07 * beat)
                let alpha1 = 0.16 + 0.18 * beat
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r1, y: cy - r1, width: 2 * r1, height: 2 * r1)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.92, blue: 0.78).opacity(alpha1),
                                Color(red: 1.0, green: 0.85, blue: 0.60).opacity(alpha1 * 0.4),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: r1))

                let innerR = baseR * 0.35 * CGFloat(1.0 + 0.22 * beat)
                let innerAlpha = 0.10 + 0.36 * beat
                ctx.fill(Path(ellipseIn: CGRect(x: cx - innerR, y: cy - innerR, width: 2 * innerR, height: 2 * innerR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.78, blue: 0.45).opacity(innerAlpha),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: innerR))
            }
        }
    }
}

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
