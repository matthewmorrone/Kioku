import SwiftUI

// Second half of KanjiDecoration+Nature.swift's decorations, split out to stay under the
// line-count guardrail. Back half of the alphabetical/thematic MARK sections — each
// decoration struct here is independently self-contained (no shared state with the first half).

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
