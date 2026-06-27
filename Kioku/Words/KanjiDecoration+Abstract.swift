import SwiftUI

// Abstract decorations — concepts (power, spirit, love, dream, divinity),
// motion verbs (go/run/fly/up/down), magnitudes (big/small), and two sound
// kanji (voice, echo) that share Sound's ring engine with different timing.

// MARK: - 力 Power (burst lines)

// Owned by KanjiDecoration.view(for:) — registered for the literal 力.
struct PowerDecoration: View {
    private let rayCount = 24

    // PUNCHY rhythmic burst — bigger rays, thicker lines, brighter flash,
    // shorter cycle (0.65s), with two layered ray sets at different angles so
    // each burst feels like an impact rather than a steady pulse. The previous
    // version was too gentle for "power."
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                let cycle: Double = 0.65
                let prog = (t / cycle).truncatingRemainder(dividingBy: 1.0)
                let maxLen: CGFloat = max(size.width, size.height) * 0.55
                let len = maxLen * CGFloat(pow(prog, 0.7))   // fast initial growth
                let alpha = 0.95 * pow(1.0 - prog, 1.6)

                // Initial bright flash on the impact — radial wash that fades fast.
                let flashR = max(size.width, size.height) * CGFloat(prog) * 0.7
                ctx.fill(Path(ellipseIn: CGRect(x: cx - flashR, y: cy - flashR, width: 2 * flashR, height: 2 * flashR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.85, blue: 0.40).opacity(0.40 * pow(1.0 - prog, 2.5)),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: flashR))

                // Outer ray layer.
                for i in 0..<rayCount {
                    let angle = (Double(i) / Double(rayCount)) * 2 * .pi
                    let startR: CGFloat = 22
                    let startX = cx + CGFloat(cos(angle)) * startR
                    let startY = cy + CGFloat(sin(angle)) * startR
                    let endX = cx + CGFloat(cos(angle)) * (startR + len)
                    let endY = cy + CGFloat(sin(angle)) * (startR + len)
                    var ray = Path()
                    ray.move(to: CGPoint(x: startX, y: startY))
                    ray.addLine(to: CGPoint(x: endX, y: endY))
                    ctx.stroke(ray,
                               with: .color(Color(red: 1.0, green: 0.55, blue: 0.18).opacity(alpha)),
                               style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                }

                // Inner shorter rays offset by half a slot for a starburst feel.
                let innerLen = len * 0.6
                for i in 0..<rayCount {
                    let angle = (Double(i) / Double(rayCount)) * 2 * .pi + .pi / Double(rayCount)
                    let startR: CGFloat = 18
                    let startX = cx + CGFloat(cos(angle)) * startR
                    let startY = cy + CGFloat(sin(angle)) * startR
                    let endX = cx + CGFloat(cos(angle)) * (startR + innerLen)
                    let endY = cy + CGFloat(sin(angle)) * (startR + innerLen)
                    var ray = Path()
                    ray.move(to: CGPoint(x: startX, y: startY))
                    ray.addLine(to: CGPoint(x: endX, y: endY))
                    ctx.stroke(ray,
                               with: .color(Color(red: 1.0, green: 0.75, blue: 0.30).opacity(alpha * 0.8)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - 気 Spirit (aura shimmer with hue cycling)

// Owned by KanjiDecoration.view(for:) — registered for the literal 気.
struct SpiritDecoration: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                // Three layered glow rings cycling through cool-warm hues.
                for i in 0..<3 {
                    let phase = Double(i) * .pi * 2 / 3
                    let cycle = sin(t * 0.6 + phase)
                    let baseR = min(size.width, size.height) * CGFloat(0.45 - Double(i) * 0.10)
                    let r = baseR * CGFloat(1.0 + 0.10 * cycle)
                    let hue = 0.55 + 0.15 * cycle
                    let color = Color(hue: hue, saturation: 0.55, brightness: 1.0)
                    let alpha = 0.18 + 0.10 * abs(cycle)
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(
                                Gradient(colors: [color.opacity(alpha), .clear]),
                                center: CGPoint(x: cx, y: cy),
                                startRadius: 0,
                                endRadius: r))
                }
            }
        }
    }
}

// MARK: - 愛 Love (rising hearts)

// Owned by KanjiDecoration.view(for:) — registered for the literal 愛.
struct LoveDecoration: View {
    private let smallHeartCount = 10

    // One large pulsing heart at the center + a swarm of smaller rising hearts
    // around it. The central heart pulses in time (heartbeat). The smaller
    // hearts drift up like emotion bubbling out. Together they read as LOVE
    // far more strongly than rising-only hearts did.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42

                // Central pulsing heart.
                let pulse = 1.0 + 0.15 * abs(sin(t * 2.2))
                drawHeart(ctx: ctx, center: CGPoint(x: cx, y: cy), scale: 5.5 * CGFloat(pulse), alpha: 0.75)

                // Rising hearts.
                let riseDuration: Double = 5.0
                for i in 0..<smallHeartCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let xSeed = haltonValue(index: i + 1, base: 3)
                    let prog = ((t / riseDuration) + phase).truncatingRemainder(dividingBy: 1.0)
                    let sway = CGFloat(sin(t * 1.5 + phase * 6.28)) * 18
                    let x = CGFloat(xSeed) * size.width + sway
                    let y = size.height - CGFloat(prog) * (size.height + 40) + 20
                    let scale: CGFloat = 0.7 + CGFloat(haltonValue(index: i + 1, base: 5)) * 0.6
                    let alpha = 0.75 * sin(prog * .pi)
                    drawHeart(ctx: ctx, center: CGPoint(x: x, y: y), scale: scale, alpha: alpha)
                }
            }
        }
    }

    // Heart-shape via two circles + a triangle (the classic stylized heart).
    private func drawHeart(ctx: GraphicsContext, center: CGPoint, scale: CGFloat, alpha: Double) {
        let lobeR: CGFloat = 6 * scale
        let lobeOffset: CGFloat = 5 * scale
        let leftLobe = CGPoint(x: center.x - lobeOffset, y: center.y - 2)
        let rightLobe = CGPoint(x: center.x + lobeOffset, y: center.y - 2)
        let bottom = CGPoint(x: center.x, y: center.y + 11 * scale)
        var path = Path()
        path.move(to: bottom)
        path.addLine(to: CGPoint(x: leftLobe.x - lobeR, y: leftLobe.y))
        path.addArc(center: leftLobe, radius: lobeR,
                    startAngle: .radians(.pi), endAngle: .radians(0),
                    clockwise: false)
        path.addArc(center: rightLobe, radius: lobeR,
                    startAngle: .radians(.pi), endAngle: .radians(0),
                    clockwise: false)
        path.addLine(to: bottom)
        path.closeSubpath()
        ctx.fill(path, with: .color(Color(red: 1.0, green: 0.40, blue: 0.55).opacity(alpha)))
    }
}

// MARK: - 夢 Dream (soft drifting bubbles + pastel tint)

// Owned by KanjiDecoration.view(for:) — registered for the literal 夢.
struct DreamDecoration: View {
    private let zCount = 9
    private let starCount = 30

    // Floating "Z"s rising from below (the universal "asleep / dream" sigil)
    // + a dreamy starfield + soft pastel wash. The Z is what makes the page
    // read as "dream" rather than just generic atmosphere.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Pastel wash.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.45, green: 0.35, blue: 0.65).opacity(0.18),
                                Color(red: 0.30, green: 0.25, blue: 0.55).opacity(0.10)
                            ]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: 0, y: size.height)))

                // Soft starfield.
                for i in 0..<starCount {
                    let x = CGFloat(haltonValue(index: i + 1, base: 2)) * size.width
                    let y = CGFloat(haltonValue(index: i + 1, base: 3)) * size.height
                    let twinkle = 0.4 + 0.6 * abs(sin(t * 0.8 + Double(i)))
                    let r: CGFloat = 1.2
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(.white.opacity(0.7 * twinkle)))
                }

                // Rising Z's — three strokes per Z forming the universal "asleep" mark.
                let riseDuration: Double = 5.5
                for i in 0..<zCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let xSeed = haltonValue(index: i + 1, base: 3)
                    let prog = ((t / riseDuration) + phase).truncatingRemainder(dividingBy: 1.0)
                    let sway = CGFloat(sin(t * 1.2 + phase * 6.28)) * 15
                    let x = CGFloat(xSeed) * size.width + sway
                    let y = size.height - CGFloat(prog) * (size.height + 50) + 25
                    let scale: CGFloat = 0.7 + CGFloat(haltonValue(index: i + 1, base: 5)) * 0.7
                    let alpha = 0.85 * sin(prog * .pi)
                    drawZ(ctx: ctx, center: CGPoint(x: x, y: y), scale: scale, alpha: alpha)
                }
            }
        }
    }

    // Draws a stylized "Z" — top bar, diagonal, bottom bar.
    private func drawZ(ctx: GraphicsContext, center: CGPoint, scale: CGFloat, alpha: Double) {
        let h: CGFloat = 14 * scale
        let w: CGFloat = 11 * scale
        let topY = center.y - h / 2
        let botY = center.y + h / 2
        let leftX = center.x - w / 2
        let rightX = center.x + w / 2
        var path = Path()
        path.move(to: CGPoint(x: leftX, y: topY))
        path.addLine(to: CGPoint(x: rightX, y: topY))
        path.addLine(to: CGPoint(x: leftX, y: botY))
        path.addLine(to: CGPoint(x: rightX, y: botY))
        ctx.stroke(path,
                   with: .color(.white.opacity(alpha)),
                   style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - 神 God / Kami (divine radial glow with rays)

// Owned by KanjiDecoration.view(for:) — registered for the literal 神.
struct DivineDecoration: View {
    private let rayCount = 24

    // Strong glow + rays emanating from the CENTER OF THE KANJI GLYPH (not
    // generic center-of-sheet) so the divinity feels like it radiates from
    // the character itself. The kanji glyph in KanjiDetailView sits around
    // y=0.22 of the sheet (hero card top). Distinct from 日's corner-sun by
    // being glyph-anchored, brighter, gold-white instead of yellow.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.22
                // Deep glow halo.
                let glowR = max(size.width, size.height) * 0.7
                ctx.fill(Path(ellipseIn: CGRect(x: cx - glowR, y: cy - glowR, width: 2 * glowR, height: 2 * glowR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.95, blue: 0.78).opacity(0.55),
                                Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.15),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: glowR))

                // Slowly rotating slim rays.
                let rotation = t * 0.10
                let rayLen = max(size.width, size.height) * 1.1
                for i in 0..<rayCount {
                    let angle = (Double(i) / Double(rayCount)) * 2 * .pi + rotation
                    let halfWidth: Double = 0.012
                    let p1 = CGPoint(x: cx, y: cy)
                    let p2 = CGPoint(x: cx + CGFloat(cos(angle - halfWidth)) * rayLen,
                                     y: cy + CGFloat(sin(angle - halfWidth)) * rayLen)
                    let p3 = CGPoint(x: cx + CGFloat(cos(angle + halfWidth)) * rayLen,
                                     y: cy + CGFloat(sin(angle + halfWidth)) * rayLen)
                    var ray = Path()
                    ray.move(to: p1)
                    ray.addLine(to: p2)
                    ray.addLine(to: p3)
                    ray.closeSubpath()
                    ctx.fill(ray,
                             with: .linearGradient(
                                Gradient(colors: [
                                    Color(red: 1.0, green: 0.95, blue: 0.65).opacity(0.40),
                                    .clear
                                ]),
                                startPoint: p1,
                                endPoint: CGPoint(x: (p2.x + p3.x) / 2, y: (p2.y + p3.y) / 2)))
                }
            }
        }
    }
}

// MARK: - 行 Go (arrows moving rightward)

// Owned by KanjiDecoration.view(for:) — registered for the literal 行.
struct GoDecoration: View {
    private let stepCount = 14

    // Footprints appearing in sequence along a slightly wandering path across
    // the sheet — left foot, right foot, left foot — fading in then fading
    // out, conveying a journey. The path curves so it doesn't read as a
    // marching column; foot shapes alternate left/right.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cycle: Double = 9.0
                let cyclePhase = (t / cycle).truncatingRemainder(dividingBy: 1.0)
                for i in 0..<stepCount {
                    let progress = Double(i) / Double(stepCount - 1)
                    let appearAt = progress
                    let timeSinceAppear = (cyclePhase - appearAt + 1.0).truncatingRemainder(dividingBy: 1.0)
                    let alpha = max(0, 1.0 - timeSinceAppear / 0.55)
                    guard alpha > 0 else { continue }
                    // Path winds gently up and down.
                    let x = CGFloat(progress) * size.width
                    let y = size.height * 0.55 + CGFloat(sin(progress * .pi * 1.8)) * 40
                    let isLeft = i % 2 == 0
                    let sideOffset: CGFloat = isLeft ? -5 : 5
                    drawFoot(ctx: ctx, center: CGPoint(x: x + sideOffset, y: y), alpha: alpha, isLeft: isLeft)
                }
            }
        }
    }

    // Single foot/shoe print — a longer oval body + small toe oval ahead of it.
    private func drawFoot(ctx: GraphicsContext, center: CGPoint, alpha: Double, isLeft: Bool) {
        let color = Color(red: 0.30, green: 0.45, blue: 0.65).opacity(alpha * 0.85)
        let footW: CGFloat = 7
        let footH: CGFloat = 12
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - footW / 2, y: center.y - footH / 2, width: footW, height: footH)),
                 with: .color(color))
        // Toe pad just ahead of the heel.
        let toeR: CGFloat = 2.5
        let toeOffset: CGFloat = isLeft ? -1 : 1
        ctx.fill(Path(ellipseIn: CGRect(x: center.x + toeOffset - toeR, y: center.y - footH / 2 - toeR + 1,
                                         width: 2 * toeR, height: 2 * toeR)),
                 with: .color(color))
    }
}

// MARK: - 上 Up (arrows rising)

// Owned by KanjiDecoration.view(for:) — registered for the literal 上.
struct UpDecoration: View {
    private let bubbleCount = 22

    // Bubbles rising naturally from the bottom — like champagne in a flute.
    // Bubble size and speed jitter per-bubble so the field feels organic.
    // Replaces the schematic "up arrows" — bubbles read as natural upward
    // movement, arrows read as a UI element.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<bubbleCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let xSeed = haltonValue(index: i + 1, base: 3)
                    let speedJitter = haltonValue(index: i + 1, base: 5)
                    let cycle = 3.0 + speedJitter * 2.5
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)
                    let lateral = CGFloat(sin(t * 1.5 + phase * 6.28)) * 14
                    let x = CGFloat(xSeed) * size.width + lateral
                    let y = size.height - CGFloat(prog) * (size.height + 20)
                    let r: CGFloat = 4 + CGFloat(haltonValue(index: i + 1, base: 7)) * 6
                    let alpha = 0.70 * sin(prog * .pi)
                    // Bubble — radial gradient with a brighter rim.
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(
                                Gradient(colors: [
                                    Color(red: 0.65, green: 0.90, blue: 1.0).opacity(alpha * 0.5),
                                    Color(red: 0.55, green: 0.85, blue: 1.0).opacity(alpha)
                                ]),
                                center: CGPoint(x: x, y: y),
                                startRadius: 0,
                                endRadius: r))
                }
            }
        }
    }
}

// MARK: - 下 Down (arrows falling)

// Owned by KanjiDecoration.view(for:) — registered for the literal 下.
struct DownDecoration: View {
    private let dropCount = 14

    // Drops falling — like rain but slower, larger, sparser, more emphasized
    // (rain is dense weather; these are individual events). Each drop is a
    // teardrop with a brief impact splash when it hits the bottom. Conveys
    // "down" through gravity, not through schematic arrows.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let bottomY = size.height * 0.92
                let fallDuration: Double = 2.6
                for i in 0..<dropCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let xSeed = haltonValue(index: i + 1, base: 3)
                    let prog = ((t / fallDuration) + phase).truncatingRemainder(dividingBy: 1.0)
                    let x = (0.06 + xSeed * 0.88) * size.width
                    if prog < 0.85 {
                        // Falling phase — drop traveling downward.
                        let fallProg = prog / 0.85
                        let y = -20 + (bottomY + 20) * CGFloat(fallProg)
                        let dropH: CGFloat = 14
                        let dropW: CGFloat = 7
                        ctx.fill(Path(ellipseIn: CGRect(x: x - dropW / 2, y: y - dropH / 2, width: dropW, height: dropH)),
                                 with: .color(Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.85)))
                    } else {
                        // Splash phase — short outward arc at the impact point.
                        let splashProg = (prog - 0.85) / 0.15
                        let splashR: CGFloat = CGFloat(splashProg) * 14
                        let alpha = 0.7 * (1.0 - splashProg)
                        var splash = Path()
                        splash.addEllipse(in: CGRect(x: x - splashR, y: bottomY - 2,
                                                      width: 2 * splashR, height: 4))
                        ctx.stroke(splash,
                                   with: .color(Color(red: 0.55, green: 0.75, blue: 1.0).opacity(alpha)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
            }
        }
    }
}

// Direction enum + arrow-field helper shared by 行 / 上 / 下. Each arrow scrolls
// across the sheet in `direction`, fading in/out at the edges via sin(progress·π).
enum ArrowDirection { case right, up, down }

// Renders a field of arrows scrolling in `direction` across the sheet. Each
// arrow has its own lane + speed jitter so the field reads as motion rather
// than a parade. Alpha fades in/out at the edges via sin(progress·π).
func drawArrowField(ctx: GraphicsContext, size: CGSize, t: Double, count: Int,
                    direction: ArrowDirection, color: Color) {
    let cycleSeconds: Double = 3.0
    for i in 0..<count {
        let phase = kanjiSeedFraction(i, 7)
        let lane = kanjiSeedFraction(i, 11)
        let speedJitter = kanjiSeedFraction(i, 17)
        let cycle = cycleSeconds * (0.8 + speedJitter * 0.6)
        let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)
        let alpha = 0.65 * sin(prog * .pi)
        let arrowSize: CGFloat = 12 + CGFloat(speedJitter) * 6
        let center: CGPoint
        let rotation: Double
        switch direction {
        case .right:
            let x = -arrowSize + (size.width + 2 * arrowSize) * CGFloat(prog)
            let y = (0.10 + lane * 0.80) * size.height
            center = CGPoint(x: x, y: y)
            rotation = 0
        case .up:
            let x = (0.05 + lane * 0.90) * size.width
            let y = size.height + arrowSize - (size.height + 2 * arrowSize) * CGFloat(prog)
            center = CGPoint(x: x, y: y)
            rotation = -.pi / 2
        case .down:
            let x = (0.05 + lane * 0.90) * size.width
            let y = -arrowSize + (size.height + 2 * arrowSize) * CGFloat(prog)
            center = CGPoint(x: x, y: y)
            rotation = .pi / 2
        }
        ctx.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(rotation))
            var arrow = Path()
            arrow.move(to: CGPoint(x: -arrowSize, y: 0))
            arrow.addLine(to: CGPoint(x: arrowSize * 0.4, y: 0))
            arrow.move(to: CGPoint(x: arrowSize * 0.4, y: -arrowSize * 0.5))
            arrow.addLine(to: CGPoint(x: arrowSize, y: 0))
            arrow.addLine(to: CGPoint(x: arrowSize * 0.4, y: arrowSize * 0.5))
            layer.stroke(arrow,
                         with: .color(color.opacity(alpha)),
                         style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 走 Run (speed lines)

// Owned by KanjiDecoration.view(for:) — registered for the literal 走.
struct RunDecoration: View {
    private let footprintCount = 14
    private let dashCount = 16

    // Footprints accelerating across the sheet + short manga-style speed dashes
    // streaming behind the runner. The footprints land at a steady cadence
    // along a left→right path; the dashes scroll fast to give the field a
    // sense of velocity. Reads as "running" rather than the previous version's
    // pure speed lines (which the user said felt more like wind).
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cycle: Double = 4.5
                let cyclePhase = (t / cycle).truncatingRemainder(dividingBy: 1.0)
                let baseY = size.height * 0.65

                // Footprints — each appears in sequence, fades out as the next lands.
                for i in 0..<footprintCount {
                    let progress = Double(i) / Double(footprintCount - 1)
                    let appearAt = progress
                    let timeSinceAppear = (cyclePhase - appearAt + 1.0).truncatingRemainder(dividingBy: 1.0)
                    let alpha = max(0, 1.0 - timeSinceAppear / 0.45)
                    guard alpha > 0 else { continue }
                    let x = CGFloat(progress) * size.width
                    let isLeft = i % 2 == 0
                    let sideOffset: CGFloat = isLeft ? -4 : 4
                    let footColor = Color(red: 0.85, green: 0.30, blue: 0.20).opacity(alpha * 0.85)
                    let footW: CGFloat = 7
                    let footH: CGFloat = 11
                    ctx.fill(Path(ellipseIn: CGRect(x: x + sideOffset - footW / 2, y: baseY - footH / 2, width: footW, height: footH)),
                             with: .color(footColor))
                }

                // Speed dashes — short fast horizontal streaks at varied heights.
                for i in 0..<dashCount {
                    let lane = haltonValue(index: i + 1, base: 2)
                    let phase = haltonValue(index: i + 1, base: 3)
                    let speedJitter = haltonValue(index: i + 1, base: 5)
                    let dashCycle = 0.35 + speedJitter * 0.4
                    let prog = ((t / dashCycle) + phase).truncatingRemainder(dividingBy: 1.0)
                    let dashLen: CGFloat = size.width * CGFloat(0.10 + speedJitter * 0.15)
                    let startX = -dashLen + (size.width + 2 * dashLen) * CGFloat(prog)
                    let y = (0.10 + lane * 0.80) * size.height
                    var dash = Path()
                    dash.move(to: CGPoint(x: startX, y: y))
                    dash.addLine(to: CGPoint(x: startX + dashLen, y: y))
                    let alpha = 0.40 * sin(prog * .pi)
                    ctx.stroke(dash,
                               with: .color(Color(red: 0.95, green: 0.55, blue: 0.30).opacity(alpha)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - 飛 Fly (long curving flight paths)

// Owned by KanjiDecoration.view(for:) — registered for the literal 飛.
struct FlyDecoration: View {
    private let archCount = 4

    // SOARING arcs — long majestic curves rising from the bottom-left, peaking
    // high overhead, and descending to the bottom-right, with a small object
    // (the flyer) traveling along each arc. Slower than the previous version
    // and with much wider curves so the motion feels graceful, like a bird
    // gliding on a thermal, not a fast dart across the sheet.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<archCount {
                    let phase = haltonValue(index: i + 1, base: 2)
                    let cycle = 7.0 + haltonValue(index: i + 1, base: 3) * 4.0
                    let prog = ((t / cycle) + phase).truncatingRemainder(dividingBy: 1.0)

                    // Arc endpoints — wide span left to right.
                    let startX: CGFloat = -40
                    let endX: CGFloat = size.width + 40
                    let startY = size.height * 0.85
                    let endY = size.height * 0.85
                    // Apex at the middle, high overhead.
                    let apexY = size.height * CGFloat(0.10 + haltonValue(index: i + 1, base: 5) * 0.20)
                    let apexX = (startX + endX) / 2

                    // Position along the arc — parabolic.
                    let t01 = prog
                    let arcX = startX + (endX - startX) * CGFloat(t01)
                    // Quadratic-bezier interpolation along (start → apex → end)
                    let oneMinus = 1 - CGFloat(t01)
                    let arcY = oneMinus * oneMinus * startY + 2 * oneMinus * CGFloat(t01) * apexY + CGFloat(t01) * CGFloat(t01) * endY

                    // Draw the trailing portion of the arc as a faded curve.
                    let trailStart = max(0, t01 - 0.35)
                    var trail = Path()
                    var s: CGFloat = CGFloat(trailStart)
                    let stepSize: CGFloat = 0.04
                    let trailStartX = startX + (endX - startX) * s
                    let trailOneMinus = 1 - s
                    let trailStartY = trailOneMinus * trailOneMinus * startY + 2 * trailOneMinus * s * apexY + s * s * endY
                    trail.move(to: CGPoint(x: trailStartX, y: trailStartY))
                    while s < CGFloat(t01) {
                        s += stepSize
                        let xx = startX + (endX - startX) * s
                        let om = 1 - s
                        let yy = om * om * startY + 2 * om * s * apexY + s * s * endY
                        trail.addLine(to: CGPoint(x: xx, y: yy))
                    }
                    let alpha = 0.55 * sin(prog * .pi)
                    ctx.stroke(trail,
                               with: .color(Color(white: 0.95).opacity(alpha * 0.55)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

                    // Flyer at the head — a small V-bird like 鳥/空.
                    let span: CGFloat = 11
                    var bird = Path()
                    bird.move(to: CGPoint(x: arcX - span, y: arcY))
                    bird.addQuadCurve(to: CGPoint(x: arcX, y: arcY - 3),
                                      control: CGPoint(x: arcX - span / 2, y: arcY - 5))
                    bird.addQuadCurve(to: CGPoint(x: arcX + span, y: arcY),
                                      control: CGPoint(x: arcX + span / 2, y: arcY - 5))
                    let _ = apexX  // silence unused-var if compiler complains; semantic anchor
                    ctx.stroke(bird,
                               with: .color(Color(white: 0.95).opacity(alpha)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - 大 Big (one giant pulse)

// Owned by KanjiDecoration.view(for:) — registered for the literal 大.
struct BigDecoration: View {
    // Enormous gradient sphere that overfills the sheet, slowly breathing —
    // OBVIOUSLY big in a way the previous half-sized version wasn't. Edges go
    // off-screen so the sphere has no visible limit, reinforcing "bigger than
    // what you can see at once."
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.40
                let pulse = 0.92 + 0.08 * sin(t * 0.7)
                let r = max(size.width, size.height) * 0.95 * CGFloat(pulse)
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color.accentColor.opacity(0.40),
                                Color.accentColor.opacity(0.20),
                                Color.accentColor.opacity(0.05),
                                .clear
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: r))
            }
        }
    }
}

// MARK: - 小 Small (many tiny vibrating dots)

// Owned by KanjiDecoration.view(for:) — registered for the literal 小.
struct SmallDecoration: View {
    // A single TINY dot inside a vast emptiness — "small" reads through scale
    // contrast, not by being lots of small things. Surrounding faint
    // crosshair-style guide lines make the dot's smallness pop. Previously
    // 80 dots scattered which felt like noise rather than "small."
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.32
                let pulse = 0.7 + 0.3 * sin(t * 1.5)
                let r: CGFloat = 3 * CGFloat(pulse)

                // Faint crosshair guides — emphasize how small the dot is.
                let guideLen: CGFloat = 60
                let guideAlpha = 0.20
                let guideColor = Color.accentColor.opacity(guideAlpha)
                var guides = Path()
                guides.move(to: CGPoint(x: cx - guideLen, y: cy))
                guides.addLine(to: CGPoint(x: cx - r * 4, y: cy))
                guides.move(to: CGPoint(x: cx + r * 4, y: cy))
                guides.addLine(to: CGPoint(x: cx + guideLen, y: cy))
                guides.move(to: CGPoint(x: cx, y: cy - guideLen))
                guides.addLine(to: CGPoint(x: cx, y: cy - r * 4))
                guides.move(to: CGPoint(x: cx, y: cy + r * 4))
                guides.addLine(to: CGPoint(x: cx, y: cy + guideLen))
                ctx.stroke(guides, with: .color(guideColor), lineWidth: 0.6)

                // The tiny dot itself.
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color.accentColor.opacity(0.95)))
            }
        }
    }
}

// MARK: - 声 Voice (small fast rings)

// Owned by KanjiDecoration.view(for:) — registered for the literal 声.
struct VoiceDecoration: View {
    private let ringCount = 5
    private let cycleSeconds: Double = 1.1

    // Smaller, faster rings than 音 — represents a voice rather than ambient
    // sound. Tighter cycle (~1.1s, near speech pulse rate) and a teal-warm tint.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                let maxR = min(size.width, size.height) * 0.50
                for i in 0..<ringCount {
                    let phase = Double(i) / Double(ringCount)
                    let prog = ((t / cycleSeconds) + phase).truncatingRemainder(dividingBy: 1.0)
                    let r = CGFloat(prog) * maxR
                    let bandWidth: CGFloat = 4
                    let inner = max(0, r - bandWidth)
                    let outer = r + bandWidth
                    let alpha = 0.55 * pow(1.0 - prog, 2.0)
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: cx - outer, y: cy - outer, width: 2 * outer, height: 2 * outer))
                    ring.addEllipse(in: CGRect(x: cx - inner, y: cy - inner, width: 2 * inner, height: 2 * inner))
                    ctx.fill(ring, with: .color(Color(red: 0.95, green: 0.55, blue: 0.40).opacity(alpha)),
                             style: FillStyle(eoFill: true))
                }
            }
        }
    }
}

// MARK: - 響 Echo (delayed echo rings)

// Owned by KanjiDecoration.view(for:) — registered for the literal 響.
struct EchoDecoration: View {
    private let echoPairs = 3   // each pair = original + echo
    private let cycleSeconds: Double = 2.4

    // Each pulse fires TWO rings — one immediately, one ~0.3s later as the
    // "echo." The echo is dimmer and slightly slower so the eye reads it as
    // a reflection of the first. Distinct from 音 by the double-pulse.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height * 0.42
                let maxR = max(size.width, size.height) * 0.7
                let echoOffset: Double = 0.20  // delay between original and echo
                for i in 0..<echoPairs {
                    let pairPhase = Double(i) / Double(echoPairs)
                    let basePhase = ((t / cycleSeconds) + pairPhase).truncatingRemainder(dividingBy: 1.0)
                    for echo in 0..<2 {
                        let echoPhase = (basePhase + (echo == 1 ? echoOffset : 0)).truncatingRemainder(dividingBy: 1.0)
                        let r = CGFloat(echoPhase) * maxR
                        let bandWidth: CGFloat = 6
                        let inner = max(0, r - bandWidth)
                        let outer = r + bandWidth
                        let baseAlpha = echo == 0 ? 0.6 : 0.30
                        let alpha = baseAlpha * pow(1.0 - echoPhase, 2.2)
                        var ring = Path()
                        ring.addEllipse(in: CGRect(x: cx - outer, y: cy - outer, width: 2 * outer, height: 2 * outer))
                        ring.addEllipse(in: CGRect(x: cx - inner, y: cy - inner, width: 2 * inner, height: 2 * inner))
                        ctx.fill(ring, with: .color(Color(red: 1.0, green: 0.7, blue: 0.25).opacity(alpha)),
                                 style: FillStyle(eoFill: true))
                    }
                }
            }
        }
    }
}
