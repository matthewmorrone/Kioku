import SwiftUI

// Conceptual decorations — for kanji that represent counts, colors, or seasons.
// Three small reusable engines drive most of these (NumberDotsDecoration,
// ColorFieldDecoration, the season-specific views), so adding more numbers /
// colors stays cheap. Registered in KanjiDecoration.view(for:).

// Halton low-discrepancy sequence in [0, 1). For (base 2, base 3) pairs the
// resulting 2D points are well-distributed with no clustering across the small-
// index range we use (1...10). Replaces `kanjiSeedFraction` for the number dots
// because that hash function near-collides at indices i and i+7, which caused
// 十 (count=10) to render with only 7 visually distinct dots — pairs 0+7, 1+8,
// 2+9 fell on top of one another.
func haltonValue(index: Int, base: Int) -> Double {
    var result = 0.0
    var f = 1.0 / Double(base)
    var i = index
    while i > 0 {
        result += f * Double(i % base)
        i /= base
        f /= Double(base)
    }
    return result
}

// MARK: - 零〜十 Numbers

// Renders N pulsing dots scattered across the sheet, so the kanji's numeric
// value reads visually at a glance — 一 shows one pulse, 三 shows three, 十 ten.
// Dot radius scales inversely with count: a single dot is large and prominent,
// ten dots are smaller so they don't overlap into a wash.
struct NumberDotsDecoration: View {
    let count: Int

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let baseR: CGFloat = count <= 3 ? 55 : (count <= 6 ? 40 : 28)
                let inset: CGFloat = baseR * 1.1
                let availableW = max(size.width - inset * 2, 1)
                // Constrain dots to the TOP HALF of the sheet so they sit behind
                // the glyph + metadata pills area, not over the readable Meanings
                // / Readings / Common words sections below the fold.
                let topHalfY = size.height * 0.5
                let availableH = max(topHalfY - inset, 1)
                for i in 0..<count {
                    // Halton low-discrepancy sequence — deterministic AND well-
                    // distributed across i. The kanjiSeedFraction hash this used to
                    // call produces near-collisions at indices i and i+7 (because
                    // 7×73 mod 256 ≈ 0), which made 十 render as 7 visible dots
                    // because three pairs overlapped almost exactly. Halton's
                    // base-2/base-3 pair has no such cycle in the small-index range.
                    let xSeed = haltonValue(index: i + 1, base: 2)
                    let ySeed = haltonValue(index: i + 1, base: 3)
                    let phase = haltonValue(index: i + 1, base: 5) * 2 * .pi
                    let pulse = 0.5 + 0.5 * sin(t * 1.4 + phase)
                    let r = baseR * CGFloat(0.7 + 0.3 * pulse)
                    let x = inset + CGFloat(xSeed) * availableW
                    let y = inset + CGFloat(ySeed) * availableH
                    let alpha = 0.18 + 0.20 * pulse
                    let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .radialGradient(
                                Gradient(colors: [
                                    Color.accentColor.opacity(alpha),
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

// Empty-set ring for 零 — a single ring expands outward from the center, fades,
// and disappears. No fill, no dot — "nothing." Staggered phases keep at least
// one visible at any time.
struct ZeroDecoration: View {
    private let particleCount = 60

    // Particles spiraling INWARD to a vanishing point — the void of zero,
    // visualized as matter falling into a center where it disappears. Each
    // particle follows a logarithmic spiral on its own phase so the field is
    // always pulling toward the middle. Distinct from the previous ring (which
    // read as just an expanding circle, not "nothingness").
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                let maxR = max(size.width, size.height) * 0.55

                // Dark central well so the eye reads "things go in here."
                let wellR = maxR * 0.12
                ctx.fill(Path(ellipseIn: CGRect(x: cx - wellR, y: cy - wellR, width: 2 * wellR, height: 2 * wellR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color.black.opacity(0.55),
                                Color.black.opacity(0)
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: wellR))

                for i in 0..<particleCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let armOffset = haltonValue(index: i + 1, base: 3) * 2 * .pi
                    let cycle: Double = 4.5
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)
                    // Radius shrinks as the particle falls into the well.
                    let r = maxR * CGFloat(1.0 - prog)
                    // Angle accelerates as r decreases — the swirl tightens.
                    let angle = armOffset + Double(1.0 - prog) * 6 * .pi
                    let x = cx + r * CGFloat(cos(angle))
                    let y = cy + r * CGFloat(sin(angle))
                    let dotR: CGFloat = 1.6
                    let alpha = 0.75 * pow(prog, 0.6)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - dotR, y: y - dotR, width: 2 * dotR, height: 2 * dotR)),
                             with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}

// MARK: - Colors

// Per-color palettes used by ColorFieldDecoration. Each entry is two tones of
// the same color so paint splotches don't all look identical, and the field
// reads as "this color with variation" rather than a flat fill.
enum KanjiColorPalette {
    static let red: [Color] = [
        Color(red: 0.92, green: 0.20, blue: 0.20),
        Color(red: 0.80, green: 0.30, blue: 0.25)
    ]
    static let blue: [Color] = [
        Color(red: 0.20, green: 0.40, blue: 0.92),
        Color(red: 0.32, green: 0.55, blue: 0.90)
    ]
    static let yellow: [Color] = [
        Color(red: 0.98, green: 0.85, blue: 0.20),
        Color(red: 0.95, green: 0.72, blue: 0.30)
    ]
    static let green: [Color] = [
        Color(red: 0.22, green: 0.68, blue: 0.30),
        Color(red: 0.40, green: 0.78, blue: 0.40)
    ]
    static let black: [Color] = [
        Color(red: 0.10, green: 0.10, blue: 0.12),
        Color(red: 0.22, green: 0.22, blue: 0.24)
    ]
    static let white: [Color] = [
        Color(white: 0.96),
        Color(white: 0.82)
    ]
}

// Field of paint splotches in the kanji's color, slowly drifting across the
// sheet. Each splotch is a radial-gradient disk that gently bobs on its own
// sine phase, so the field breathes rather than static-tiles. Higher alpha
// than the ambient decorations — the color IS the point.
struct ColorFieldDecoration: View {
    let palette: [Color]
    private let splotchCount = 14

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<splotchCount {
                    // Halton — same hash-collision fix as NumberDotsDecoration.
                    // kanjiSeedFraction made pairs (i, i+7) overlap, so 14
                    // splotches read visually as 7.
                    let xSeed = haltonValue(index: i + 1, base: 2)
                    let ySeed = haltonValue(index: i + 1, base: 3)
                    let phase = haltonValue(index: i + 1, base: 5) * 2 * .pi
                    let driftX = CGFloat(sin(t * 0.4 + phase) * 14)
                    let driftY = CGFloat(cos(t * 0.3 + phase) * 12)
                    let radius: CGFloat = 36 + CGFloat(kanjiSeedFraction(i, 23)) * 28
                    let x = (0.05 + xSeed * 0.90) * size.width + driftX
                    let y = (0.05 + ySeed * 0.90) * size.height + driftY
                    let color = palette[i % palette.count]
                    let alpha = 0.22 + sin(t * 0.6 + phase) * 0.08
                    ctx.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .radialGradient(
                                Gradient(colors: [color.opacity(alpha), .clear]),
                                center: CGPoint(x: x, y: y),
                                startRadius: 0,
                                endRadius: radius))
                }
            }
        }
    }
}

// MARK: - 春 Spring (cherry blossoms)

// Pink cherry-blossom petals falling slowly, swaying side to side as they drift
// down. Each petal is an elongated rounded shape rotated on its own axis. Lower
// count than rain/snow so the petals read as distinct objects, not a wash.
struct SpringDecoration: View {
    private let petalCount = 16

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let fallDuration: Double = 10.0
                for i in 0..<petalCount {
                    let phase = kanjiSeedFraction(i, 7)
                    let xSeed = kanjiSeedFraction(i, 11)
                    let prog = ((t / fallDuration) + phase).truncatingRemainder(dividingBy: 1.0)
                    let swayPhase = phase * 6.28
                    let sway = sin(t * 0.8 + swayPhase) * 30
                    let x = CGFloat(xSeed) * size.width + CGFloat(sway)
                    let y = -20 + (size.height + 40) * CGFloat(prog)
                    let petalLen: CGFloat = 11 + CGFloat(kanjiSeedFraction(i, 17)) * 5
                    let petalWidth: CGFloat = petalLen * 0.65
                    let rotation = sin(t * 1.5 + swayPhase) * 1.0
                    let pinkBias = kanjiSeedFraction(i, 23)
                    let color = pinkBias > 0.5
                        ? Color(red: 1.0, green: 0.75, blue: 0.85)
                        : Color(red: 0.98, green: 0.82, blue: 0.90)

                    ctx.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(rotation))
                        let rect = CGRect(x: -petalWidth / 2, y: -petalLen / 2, width: petalWidth, height: petalLen)
                        layer.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
                    }
                }
            }
        }
    }
}

// MARK: - 夏 Summer (heat + sun)

// Hot bright sun in the upper area + heat-shimmer bands rising from the ground.
// Shimmer is a stack of wavy vertical lines whose horizontal sine displacement
// is time-driven, so the air looks like it's distorting from heat without
// needing a fragment shader. Warm color wash anchors the summer palette.
struct SummerDecoration: View {
    private let shimmerCount = 14

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Warm tint wash at the top.
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.5)),
                         with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.55, blue: 0.25).opacity(0.22),
                                .clear
                            ]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: 0, y: size.height * 0.5)))

                // Hot sun glow centered upper-right.
                let sunCx = size.width * 0.72
                let sunCy = size.height * 0.16
                let sunR: CGFloat = max(size.width, size.height) * 0.32
                ctx.fill(Path(ellipseIn: CGRect(x: sunCx - sunR, y: sunCy - sunR, width: 2 * sunR, height: 2 * sunR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.92, blue: 0.55).opacity(0.55),
                                Color(red: 1.0, green: 0.65, blue: 0.30).opacity(0.15),
                                .clear
                            ]),
                            center: CGPoint(x: sunCx, y: sunCy),
                            startRadius: 0,
                            endRadius: sunR))

                // Heat-shimmer bands: vertical wavy lines from ground up.
                for i in 0..<shimmerCount {
                    let xBase = (Double(i) + 0.5) / Double(shimmerCount) * Double(size.width)
                    let amp = 4 + kanjiSeedFraction(i, 7) * 6
                    let speed = 1.5 + kanjiSeedFraction(i, 11) * 1.0
                    let phaseSeed = kanjiSeedFraction(i, 17) * 6.28
                    var path = Path()
                    var y = size.height
                    let startX = CGFloat(xBase + amp * sin(Double(y) * 0.04 + t * speed + phaseSeed))
                    path.move(to: CGPoint(x: startX, y: y))
                    while y >= 0 {
                        y -= 6
                        let x = CGFloat(xBase + amp * sin(Double(y) * 0.04 + t * speed + phaseSeed))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    let alpha = 0.18
                    ctx.stroke(path,
                               with: .color(Color(red: 1.0, green: 0.88, blue: 0.65).opacity(alpha)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - 秋 Autumn (falling fall-colored leaves)

// Falling leaves in the autumn palette — orange, amber, red-orange, gold-brown
// — each rotating slowly as it drifts down. Distinct from 木's green-leaf drift
// by the warm color range and the heavier fall density.
struct AutumnDecoration: View {
    private let leafCount = 18

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let fallDuration: Double = 8.0
                for i in 0..<leafCount {
                    let phase = kanjiSeedFraction(i, 7)
                    let xSeed = kanjiSeedFraction(i, 11)
                    let prog = ((t / fallDuration) + phase).truncatingRemainder(dividingBy: 1.0)
                    let sway = sin(t * 1.0 + phase * 6.28) * 26
                    let x = CGFloat(xSeed) * size.width + CGFloat(sway)
                    let y = -20 + (size.height + 40) * CGFloat(prog)
                    let rotation = sin(t * 1.4 + phase * 4) * 1.2

                    let colorIndex = i % 4
                    let color: Color
                    switch colorIndex {
                    case 0: color = Color(red: 0.88, green: 0.45, blue: 0.15)  // orange
                    case 1: color = Color(red: 0.95, green: 0.62, blue: 0.20)  // amber
                    case 2: color = Color(red: 0.78, green: 0.25, blue: 0.15)  // red-orange
                    default: color = Color(red: 0.75, green: 0.58, blue: 0.22) // gold-brown
                    }

                    let leafSize: CGFloat = 13
                    ctx.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(rotation))
                        let rect = CGRect(x: -leafSize / 2, y: -leafSize * 0.7, width: leafSize, height: leafSize * 1.4)
                        layer.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
                        var stem = Path()
                        stem.move(to: CGPoint(x: 0, y: leafSize * 0.7))
                        stem.addLine(to: CGPoint(x: 0, y: leafSize * 0.95))
                        layer.stroke(stem, with: .color(color.opacity(0.7)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

// MARK: - 冬 Winter (frost + cold snow)

// Cold winter atmosphere — pale blue ambient tint, frost crystals growing
// inward from each corner of the sheet, and a small number of large slow
// snowflakes drifting through. Distinct from 雪 (active dense snowfall):
// 冬 reads as the SETTING of winter, not weather in progress.
struct WinterDecoration: View {
    private let snowCount = 9

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Cold blue ambient tint across the sheet.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.78, green: 0.88, blue: 1.0).opacity(0.16),
                                Color(red: 0.78, green: 0.88, blue: 1.0).opacity(0.04),
                                Color(red: 0.78, green: 0.88, blue: 1.0).opacity(0.16)
                            ]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: 0, y: size.height)))

                // Frost crystals fanning inward from each corner.
                drawFrost(ctx: ctx, size: size, t: t)

                // Slow large snowflakes drifting down.
                let fallDuration: Double = 16.0
                for i in 0..<snowCount {
                    let phase = kanjiSeedFraction(i, 7)
                    let xSeed = kanjiSeedFraction(i, 11)
                    let prog = ((t / fallDuration) + phase).truncatingRemainder(dividingBy: 1.0)
                    let sway = sin(t * 0.5 + phase * 6.28) * 18
                    let x = CGFloat(xSeed) * size.width + CGFloat(sway)
                    let y = -10 + (size.height + 20) * CGFloat(prog)
                    let r: CGFloat = 4 + CGFloat(kanjiSeedFraction(i, 17)) * 3
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(
                                Gradient(colors: [
                                    Color.white.opacity(0.95),
                                    Color.white.opacity(0)
                                ]),
                                center: CGPoint(x: x, y: y),
                                startRadius: 0,
                                endRadius: r))
                }
            }
        }
    }

    // Renders thin radiating ice lines fanning inward from each corner, each
    // with two small branches near the tip for a dendritic frost look. Length
    // breathes very slowly on a sine so the frost feels alive without melting.
    private func drawFrost(ctx: GraphicsContext, size: CGSize, t: Double) {
        let rayCount = 7
        let baseLen: CGFloat = max(size.width, size.height) * 0.30
        let corners: [(CGPoint, Double)] = [
            (CGPoint(x: 0, y: 0), 0),                      // fan into ↘
            (CGPoint(x: size.width, y: 0), .pi / 2),       // fan into ↙
            (CGPoint(x: size.width, y: size.height), .pi), // fan into ↖
            (CGPoint(x: 0, y: size.height), 3 * .pi / 2)   // fan into ↗
        ]
        let breathe = CGFloat(0.92 + sin(t * 0.6) * 0.05)
        for (corner, baseAngle) in corners {
            for r in 0..<rayCount {
                let spread = (Double(r) / Double(rayCount - 1)) * (.pi / 2) // 0 → 90°
                let angle = baseAngle + spread
                let lenJitter = 0.7 + kanjiSeedFraction(r, 7) * 0.3
                let length = baseLen * breathe * CGFloat(lenJitter)
                let endX = corner.x + CGFloat(cos(angle)) * length
                let endY = corner.y + CGFloat(sin(angle)) * length
                var path = Path()
                path.move(to: corner)
                path.addLine(to: CGPoint(x: endX, y: endY))
                ctx.stroke(path,
                           with: .color(Color(red: 0.85, green: 0.94, blue: 1.0).opacity(0.55)),
                           style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

                // Two small branches near the tip — dendritic frost.
                let branchOrigin = CGPoint(x: corner.x + CGFloat(cos(angle)) * length * 0.7,
                                           y: corner.y + CGFloat(sin(angle)) * length * 0.7)
                for sideSign in [-1.0, 1.0] {
                    let branchAngle = angle + sideSign * .pi / 6
                    let branchLen = length * 0.20
                    var branch = Path()
                    branch.move(to: branchOrigin)
                    branch.addLine(to: CGPoint(x: branchOrigin.x + CGFloat(cos(branchAngle)) * branchLen,
                                               y: branchOrigin.y + CGFloat(sin(branchAngle)) * branchLen))
                    ctx.stroke(branch,
                               with: .color(Color(red: 0.85, green: 0.94, blue: 1.0).opacity(0.45)),
                               style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                }
            }
        }
    }
}
