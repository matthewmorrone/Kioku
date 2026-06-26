import SwiftUI

// Beings + times of day — kanji for animals, the day's phases, and one body
// part (目 eye). Animal silhouettes are deliberately simple geometric shapes
// rather than illustrations; at decoration alpha they read as "small creature
// moving" without needing to be artwork.

// MARK: - 朝 Morning (sunrise)

// Owned by KanjiDecoration.view(for:) — registered for the literal 朝.
struct MorningDecoration: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Soft pink sky gradient near the horizon (subtly time-varying).
                let breathe = 0.85 + 0.15 * sin(t * 0.5)
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [
                                .clear,
                                Color(red: 1.0, green: 0.78, blue: 0.65).opacity(0.30 * breathe),
                                Color(red: 1.0, green: 0.65, blue: 0.45).opacity(0.45 * breathe)
                            ]),
                            startPoint: CGPoint(x: 0, y: size.height * 0.40),
                            endPoint: CGPoint(x: 0, y: size.height * 0.85)))

                // Sunrise sun — just peeking over the horizon at center-bottom.
                let sunCx = size.width * 0.55
                let sunCy = size.height * 0.85
                let sunR: CGFloat = 70
                ctx.fill(Path(ellipseIn: CGRect(x: sunCx - sunR, y: sunCy - sunR, width: 2 * sunR, height: 2 * sunR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.92, blue: 0.55).opacity(0.85),
                                Color(red: 1.0, green: 0.65, blue: 0.30).opacity(0.25),
                                .clear
                            ]),
                            center: CGPoint(x: sunCx, y: sunCy),
                            startRadius: 0,
                            endRadius: sunR))
            }
        }
    }
}

// MARK: - 夜 Night (dark sky + dense stars)

// Owned by KanjiDecoration.view(for:) — registered for the literal 夜.
struct NightDecoration: View {
    private let starCount = 140

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Dark vignette — corners darker than the center.
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color.black.opacity(0.15),
                                Color.black.opacity(0.45)
                            ]),
                            center: CGPoint(x: size.width / 2, y: size.height / 2),
                            startRadius: 50,
                            endRadius: max(size.width, size.height)))

                // Dense starfield (like StarDecoration but quieter, more numerous).
                for i in 0..<starCount {
                    let x = CGFloat(kanjiSeedFraction(i, 3)) * size.width
                    let y = CGFloat(kanjiSeedFraction(i, 7)) * size.height
                    let phase = kanjiSeedFraction(i, 11) * 2 * .pi
                    let twinkle = 0.5 + 0.5 * sin(t * 0.6 + phase)
                    let r: CGFloat = i % 14 == 0 ? 2.2 : (i % 4 == 0 ? 1.3 : 0.7)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                             with: .color(.white.opacity((0.55 + 0.45 * twinkle) * 0.85)))
                }
            }
        }
    }
}

// MARK: - 夕 Evening (sunset)

// Owned by KanjiDecoration.view(for:) — registered for the literal 夕.
struct EveningDecoration: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Sunset orange-purple gradient bottom-up.
                let breathe = 0.85 + 0.15 * sin(t * 0.4)
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.30, green: 0.20, blue: 0.50).opacity(0.30 * breathe),
                                Color(red: 0.95, green: 0.45, blue: 0.35).opacity(0.50 * breathe),
                                Color(red: 1.0, green: 0.62, blue: 0.30).opacity(0.55 * breathe)
                            ]),
                            startPoint: CGPoint(x: 0, y: size.height * 0.10),
                            endPoint: CGPoint(x: 0, y: size.height * 0.90)))

                // Low sun on the horizon — fuller than morning's peek.
                let sunCx = size.width * 0.65
                let sunCy = size.height * 0.78
                let sunR: CGFloat = 60
                ctx.fill(Path(ellipseIn: CGRect(x: sunCx - sunR, y: sunCy - sunR, width: 2 * sunR, height: 2 * sunR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1.0, green: 0.80, blue: 0.35).opacity(0.95),
                                Color(red: 0.95, green: 0.50, blue: 0.25).opacity(0.4),
                                .clear
                            ]),
                            center: CGPoint(x: sunCx, y: sunCy),
                            startRadius: 0,
                            endRadius: sunR))
            }
        }
    }
}

// MARK: - 鳥 Bird (flying silhouette)

// Owned by KanjiDecoration.view(for:) — registered for the literal 鳥.
struct BirdDecoration: View {
    private let flockCount = 3            // number of flock groups
    private let birdsPerFlock = 7         // birds in each V-formation

    // Flocks of birds in V-formation rather than scattered solo silhouettes.
    // Each flock has a lead bird at the front of a V, with wings of birds
    // trailing behind on both sides. Three flocks at different altitudes and
    // speeds give the sky a sense of distance — far flock smaller and slower.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for flock in 0..<flockCount {
                    let baseY = CGFloat(0.12 + Double(flock) / Double(flockCount) * 0.45) * size.height
                    let speed = 40.0 + Double(flock) * 10.0
                    let scaleFactor = 1.0 - Double(flock) * 0.20
                    let phase = haltonValue(index: flock + 1, base: 2)
                    let leadX = (CGFloat(phase) * size.width + CGFloat(t * speed))
                        .truncatingRemainder(dividingBy: size.width + 160) - 80

                    for b in 0..<birdsPerFlock {
                        let row = (b + 1) / 2   // 0 for lead, then 1,1,2,2,3,3
                        let side: CGFloat = b == 0 ? 0 : (b % 2 == 0 ? 1 : -1)
                        let offsetX = -CGFloat(row) * 18
                        let offsetY = CGFloat(row) * 7 * abs(side)
                        let flap = sin(t * 5.0 + Double(b) * 0.4) * 2.5
                        let center = CGPoint(x: leadX + offsetX,
                                             y: baseY + offsetY + CGFloat(side) * 0)
                        let span: CGFloat = CGFloat(11 * scaleFactor)
                        var path = Path()
                        path.move(to: CGPoint(x: center.x - span, y: center.y + CGFloat(flap)))
                        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - 2),
                                          control: CGPoint(x: center.x - span / 2, y: center.y - 3 + CGFloat(flap)))
                        path.addQuadCurve(to: CGPoint(x: center.x + span, y: center.y + CGFloat(flap)),
                                          control: CGPoint(x: center.x + span / 2, y: center.y - 3 + CGFloat(flap)))
                        ctx.stroke(path,
                                   with: .color(Color(red: 0.16, green: 0.20, blue: 0.26).opacity(0.85 * scaleFactor)),
                                   style: StrokeStyle(lineWidth: CGFloat(1.8 * scaleFactor), lineCap: .round, lineJoin: .round))

                        // Mirror to the other side for the V.
                        if side != 0 {
                            let mirrorCenter = CGPoint(x: leadX + offsetX,
                                                       y: baseY - offsetY)
                            var mirror = Path()
                            mirror.move(to: CGPoint(x: mirrorCenter.x - span, y: mirrorCenter.y + CGFloat(flap)))
                            mirror.addQuadCurve(to: CGPoint(x: mirrorCenter.x, y: mirrorCenter.y - 2),
                                                control: CGPoint(x: mirrorCenter.x - span / 2, y: mirrorCenter.y - 3 + CGFloat(flap)))
                            mirror.addQuadCurve(to: CGPoint(x: mirrorCenter.x + span, y: mirrorCenter.y + CGFloat(flap)),
                                                control: CGPoint(x: mirrorCenter.x + span / 2, y: mirrorCenter.y - 3 + CGFloat(flap)))
                            ctx.stroke(mirror,
                                       with: .color(Color(red: 0.16, green: 0.20, blue: 0.26).opacity(0.85 * scaleFactor)),
                                       style: StrokeStyle(lineWidth: CGFloat(1.8 * scaleFactor), lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 魚 Fish (swimming silhouettes)

// Owned by KanjiDecoration.view(for:) — registered for the literal 魚.
struct FishDecoration: View {
    private let schoolCount = 2          // two schools
    private let fishPerSchool = 9        // fish per school

    // Two schools of fish swimming together — each school is a tight cluster
    // of fish on similar trajectories with small per-fish jitter so it reads
    // as a school, not a parade. Schools go opposite directions at different
    // depths so the sheet feels populated rather than rhythmic.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for school in 0..<schoolCount {
                    let baseY = CGFloat(0.30 + Double(school) * 0.40) * size.height
                    let direction: CGFloat = school == 0 ? 1.0 : -1.0
                    let speed = 24.0 + Double(school) * 6.0
                    let scrollBase = CGFloat(t * speed) * direction
                    let leadX = direction > 0
                        ? scrollBase.truncatingRemainder(dividingBy: size.width + 200) - 100
                        : (size.width + 100) - scrollBase.truncatingRemainder(dividingBy: size.width + 200)

                    for i in 0..<fishPerSchool {
                        let offsetXSeed = haltonValue(index: i + 1, base: 2)
                        let offsetYSeed = haltonValue(index: i + 1, base: 3)
                        let offsetX = -CGFloat(offsetXSeed * 110) * direction
                        let offsetY = CGFloat((offsetYSeed - 0.5) * 50)
                        let bob = CGFloat(sin(t * 2.5 + Double(i) * 0.7)) * 3
                        let center = CGPoint(x: leadX + offsetX,
                                             y: baseY + offsetY + bob)
                        let bodyW: CGFloat = 18
                        let bodyH: CGFloat = 8
                        ctx.drawLayer { layer in
                            layer.translateBy(x: center.x, y: center.y)
                            layer.scaleBy(x: direction, y: 1)
                            layer.fill(Path(ellipseIn: CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH)),
                                       with: .color(Color(red: 0.30, green: 0.50, blue: 0.78).opacity(0.78)))
                            var tail = Path()
                            tail.move(to: CGPoint(x: -bodyW / 2, y: 0))
                            tail.addLine(to: CGPoint(x: -bodyW / 2 - 6, y: -4))
                            tail.addLine(to: CGPoint(x: -bodyW / 2 - 6, y: 4))
                            tail.closeSubpath()
                            layer.fill(tail, with: .color(Color(red: 0.30, green: 0.50, blue: 0.78).opacity(0.78)))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 馬 Horse (galloping silhouette)

// Owned by KanjiDecoration.view(for:) — registered for the literal 馬.
struct HorseDecoration: View {
    // Stylized horse silhouette (round body + four short legs + slim neck + tail)
    // running across the bottom. Legs alternate up/down to suggest a gallop;
    // mane streams behind based on motion.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let speed = 80.0
                let scrollX = CGFloat(t * speed).truncatingRemainder(dividingBy: size.width + 150) - 80
                let baseY = size.height * 0.78
                drawHorse(ctx: ctx, center: CGPoint(x: scrollX, y: baseY), t: t)
            }
        }
    }

    // Draws a single horse silhouette at `center` — body ellipse + tail + neck
    // wedge + head + four legs whose lift alternates on the gallop cycle.
    private func drawHorse(ctx: GraphicsContext, center: CGPoint, t: Double) {
        let bodyW: CGFloat = 56
        let bodyH: CGFloat = 26
        let color = Color(red: 0.30, green: 0.20, blue: 0.16).opacity(0.85)
        ctx.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            // Body
            layer.fill(Path(ellipseIn: CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH)),
                       with: .color(color))
            // Neck + head — tilted forward up-right.
            var neck = Path()
            neck.move(to: CGPoint(x: bodyW / 2 - 4, y: -bodyH / 2 + 2))
            neck.addLine(to: CGPoint(x: bodyW / 2 + 8, y: -bodyH / 2 - 14))
            neck.addLine(to: CGPoint(x: bodyW / 2 + 18, y: -bodyH / 2 - 14))
            neck.addLine(to: CGPoint(x: bodyW / 2 + 2, y: -bodyH / 2 + 4))
            neck.closeSubpath()
            layer.fill(neck, with: .color(color))
            // Head
            layer.fill(Path(ellipseIn: CGRect(x: bodyW / 2 + 8, y: -bodyH / 2 - 22, width: 14, height: 11)),
                       with: .color(color))
            // Tail — streams behind
            var tail = Path()
            tail.move(to: CGPoint(x: -bodyW / 2 + 2, y: -bodyH / 2 + 4))
            tail.addQuadCurve(to: CGPoint(x: -bodyW / 2 - 14, y: 0),
                              control: CGPoint(x: -bodyW / 2 - 8, y: -bodyH / 2 - 4))
            layer.stroke(tail, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            // Four legs — alternate lift cycle.
            let lift = sin(t * 12) * 4
            let legY = bodyH / 2 - 2
            let legLen: CGFloat = 18
            let legPositions: [CGFloat] = [-bodyW / 2 + 6, -bodyW / 2 + 18, bodyW / 2 - 18, bodyW / 2 - 6]
            for (i, lx) in legPositions.enumerated() {
                let bend = (i % 2 == 0) ? CGFloat(lift) : -CGFloat(lift)
                var leg = Path()
                leg.move(to: CGPoint(x: lx, y: legY))
                leg.addLine(to: CGPoint(x: lx + bend * 0.3, y: legY + legLen))
                layer.stroke(leg, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
    }
}

// MARK: - 犬 Dog (paw prints)

// Owned by KanjiDecoration.view(for:) — registered for the literal 犬.
struct DogDecoration: View {
    // Dog silhouette running across the bottom — body + head + tail + four
    // legs in a galloping cycle, plus a paw-print trail it leaves behind.
    // The paw trail gives the running dog continuity; the silhouette gives it
    // identity. Previously was just paw prints, which the user found too
    // abstract to read as "dog."
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let speed = 80.0
                let scrollX = CGFloat(t * speed).truncatingRemainder(dividingBy: size.width + 150) - 80
                let baseY = size.height * 0.82
                // Trail of recent paw prints behind the dog.
                let trailCount = 6
                for p in 0..<trailCount {
                    let trailX = scrollX - CGFloat(p) * 18 - 30
                    let trailY = baseY + 12 + CGFloat(p % 2 == 0 ? 0 : 3)
                    let alpha = 0.55 * (1.0 - Double(p) / Double(trailCount))
                    drawPawPrint(ctx: ctx, center: CGPoint(x: trailX, y: trailY), alpha: alpha)
                }
                drawDog(ctx: ctx, center: CGPoint(x: scrollX, y: baseY), t: t)
            }
        }
    }

    // Single small paw print used by the trail behind the running dog.
    private func drawPawPrint(ctx: GraphicsContext, center: CGPoint, alpha: Double) {
        guard alpha > 0 else { return }
        let color = Color(red: 0.40, green: 0.26, blue: 0.16).opacity(alpha * 0.85)
        let heelW: CGFloat = 5
        let heelH: CGFloat = 4
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - heelW / 2, y: center.y - heelH / 2, width: heelW, height: heelH)),
                 with: .color(color))
        for toe in 0..<3 {
            let angle = -.pi / 2 + (Double(toe) - 1) * 0.5
            let toeX = center.x + CGFloat(cos(angle)) * 5
            let toeY = center.y + CGFloat(sin(angle)) * 5
            let toeR: CGFloat = 1.4
            ctx.fill(Path(ellipseIn: CGRect(x: toeX - toeR, y: toeY - toeR, width: 2 * toeR, height: 2 * toeR)),
                     with: .color(color))
        }
    }

    // Dog silhouette at `center` — long body, square head with floppy ear,
    // tail held high, four legs with a gallop bend.
    private func drawDog(ctx: GraphicsContext, center: CGPoint, t: Double) {
        let bodyW: CGFloat = 46
        let bodyH: CGFloat = 18
        let color = Color(red: 0.28, green: 0.18, blue: 0.12).opacity(0.88)
        ctx.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            // Body
            layer.fill(Path(ellipseIn: CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH)),
                       with: .color(color))
            // Head — round, with snout extending forward
            layer.fill(Path(ellipseIn: CGRect(x: bodyW / 2 - 6, y: -bodyH / 2 - 4, width: 14, height: 12)),
                       with: .color(color))
            layer.fill(Path(ellipseIn: CGRect(x: bodyW / 2 + 5, y: -bodyH / 2 + 2, width: 9, height: 6)),
                       with: .color(color))
            // Floppy ear
            var ear = Path()
            ear.move(to: CGPoint(x: bodyW / 2 - 2, y: -bodyH / 2 - 2))
            ear.addQuadCurve(to: CGPoint(x: bodyW / 2 + 4, y: -bodyH / 2 + 6),
                             control: CGPoint(x: bodyW / 2, y: -bodyH / 2 - 6))
            ear.addLine(to: CGPoint(x: bodyW / 2 - 1, y: -bodyH / 2 + 2))
            ear.closeSubpath()
            layer.fill(ear, with: .color(color))
            // Tail held up
            var tail = Path()
            tail.move(to: CGPoint(x: -bodyW / 2 + 2, y: -bodyH / 2 + 4))
            tail.addQuadCurve(to: CGPoint(x: -bodyW / 2 - 8, y: -bodyH / 2 - 10),
                              control: CGPoint(x: -bodyW / 2 - 2, y: -bodyH / 2 - 4))
            layer.stroke(tail, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // Four legs — galloping (front pair lift opposite to back pair).
            let frontLift = sin(t * 10) * 4
            let backLift = -frontLift
            let legY = bodyH / 2 - 2
            let legLen: CGFloat = 13
            let legPositions: [(x: CGFloat, lift: Double)] = [
                (-bodyW / 2 + 6, backLift),
                (-bodyW / 2 + 16, backLift),
                (bodyW / 2 - 16, frontLift),
                (bodyW / 2 - 6, frontLift)
            ]
            for leg in legPositions {
                var legPath = Path()
                legPath.move(to: CGPoint(x: leg.x, y: legY))
                legPath.addLine(to: CGPoint(x: leg.x + CGFloat(leg.lift) * 0.2, y: legY + legLen - CGFloat(abs(leg.lift)) * 0.5))
                layer.stroke(legPath, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }
}

// MARK: - 猫 Cat (silhouette + tail flick)

// Owned by KanjiDecoration.view(for:) — registered for the literal 猫.
struct CatDecoration: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let speed = 30.0
                let scrollX = CGFloat(t * speed).truncatingRemainder(dividingBy: size.width + 120) - 60
                let baseY = size.height * 0.82
                drawCat(ctx: ctx, center: CGPoint(x: scrollX, y: baseY), t: t)
            }
        }
    }

    // Draws a single cat silhouette at `center` — body + head + two pointy ears
    // + tail (flicking with a sine) + two short legs. Black at high alpha.
    private func drawCat(ctx: GraphicsContext, center: CGPoint, t: Double) {
        let color = Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.88)
        let bodyW: CGFloat = 34
        let bodyH: CGFloat = 14
        ctx.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            // Body
            layer.fill(Path(ellipseIn: CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH)),
                       with: .color(color))
            // Head
            layer.fill(Path(ellipseIn: CGRect(x: bodyW / 2 - 6, y: -bodyH / 2 - 8, width: 14, height: 12)),
                       with: .color(color))
            // Two pointy ears
            var ears = Path()
            ears.move(to: CGPoint(x: bodyW / 2 - 4, y: -bodyH / 2 - 6))
            ears.addLine(to: CGPoint(x: bodyW / 2 - 2, y: -bodyH / 2 - 14))
            ears.addLine(to: CGPoint(x: bodyW / 2, y: -bodyH / 2 - 6))
            ears.move(to: CGPoint(x: bodyW / 2 + 2, y: -bodyH / 2 - 6))
            ears.addLine(to: CGPoint(x: bodyW / 2 + 4, y: -bodyH / 2 - 14))
            ears.addLine(to: CGPoint(x: bodyW / 2 + 6, y: -bodyH / 2 - 6))
            layer.fill(ears, with: .color(color))
            // Tail — flicks with sine
            let flick = sin(t * 3) * 0.5
            var tail = Path()
            tail.move(to: CGPoint(x: -bodyW / 2 + 2, y: -bodyH / 2 + 4))
            tail.addQuadCurve(to: CGPoint(x: -bodyW / 2 - 12, y: -bodyH / 2 - 10 + CGFloat(flick) * 8),
                              control: CGPoint(x: -bodyW / 2 - 4, y: -bodyH / 2 - 4))
            layer.stroke(tail, with: .color(color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            // Legs — simple short verticals
            let legY = bodyH / 2 - 2
            for lx in [-bodyW / 2 + 6, bodyW / 2 - 8] as [CGFloat] {
                var leg = Path()
                leg.move(to: CGPoint(x: lx, y: legY))
                leg.addLine(to: CGPoint(x: lx, y: legY + 10))
                layer.stroke(leg, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }
}

// MARK: - 虫 Insect (tiny scuttling bugs)

// Owned by KanjiDecoration.view(for:) — registered for the literal 虫.
struct InsectDecoration: View {
    private let dragonflyCount = 7

    // Dragonflies darting around — each is a slender body + four wing ovals
    // that beat very fast (faster than the eye can resolve, like real wings).
    // The dragonflies follow slow Lissajous paths so they appear to hover,
    // dart, change direction. Distinct from the previous "dark dots with leg
    // lines" which didn't read as bugs.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<dragonflyCount {
                    let xSeed = haltonValue(index: i + 1, base: 2)
                    let ySeed = haltonValue(index: i + 1, base: 3)
                    let phaseX = haltonValue(index: i + 1, base: 5) * 6.28
                    let phaseY = haltonValue(index: i + 1, base: 7) * 6.28
                    let radiusX: CGFloat = 50 + CGFloat(haltonValue(index: i + 1, base: 11)) * 60
                    let radiusY: CGFloat = 30 + CGFloat(haltonValue(index: i + 1, base: 13)) * 50
                    let cx = (0.12 + xSeed * 0.76) * size.width
                    let cy = (0.10 + ySeed * 0.80) * size.height
                    let x = cx + radiusX * CGFloat(sin(t * 0.9 + phaseX))
                    let y = cy + radiusY * CGFloat(cos(t * 0.7 + phaseY))
                    // Heading: tangent to the flight curve.
                    let heading = atan2(-radiusY * sin(t * 0.7 + phaseY) * 0.7,
                                         radiusX * cos(t * 0.9 + phaseX) * 0.9)
                    let wingBeat = sin(t * 22 + Double(i)) * 0.5 + 1.0  // 22Hz = blurred

                    ctx.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(heading))
                        let bodyColor = Color(red: 0.15, green: 0.20, blue: 0.30).opacity(0.85)
                        let wingColor = Color(red: 0.55, green: 0.70, blue: 0.85).opacity(0.45)
                        // Slender body
                        layer.fill(Path(ellipseIn: CGRect(x: -8, y: -1, width: 16, height: 2)),
                                   with: .color(bodyColor))
                        // Head
                        layer.fill(Path(ellipseIn: CGRect(x: 6, y: -2, width: 4, height: 4)),
                                   with: .color(bodyColor))
                        // Four wings — fore pair + hind pair, oval, perpendicular to body
                        let wingLen: CGFloat = CGFloat(6 * wingBeat)
                        let wingThick: CGFloat = 3
                        for side: CGFloat in [-1, 1] {
                            for xOff: CGFloat in [-1, 4] {
                                let wingRect = CGRect(x: xOff - wingLen / 2, y: side * 2, width: wingLen, height: wingThick)
                                layer.fill(Path(ellipseIn: wingRect),
                                           with: .color(wingColor))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 目 Eye (slow blink)

// Owned by KanjiDecoration.view(for:) — registered for the literal 目.
struct EyeDecoration: View {
    @State private var blink: Double = 0
    @State private var pupilDilation: Double = 0

    // A single large iris filling the upper area, slowly dilating and
    // contracting + an occasional blink (rendered as a horizontal lid
    // closing over the iris). No drawn eye outline — the iris IS the visual.
    // The previous outlined-almond shape read more like a clip-art logo than
    // an eye watching you.
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let eyeCx = size.width / 2
                let eyeCy = size.height * 0.30
                let irisR: CGFloat = min(size.width, size.height) * 0.16
                let dilation = 0.5 + 0.5 * sin(t * 0.4)
                let pupilR: CGFloat = irisR * CGFloat(0.30 + 0.10 * dilation)

                // Iris — gradient from a deep core out to the iris edge.
                ctx.fill(Path(ellipseIn: CGRect(x: eyeCx - irisR, y: eyeCy - irisR, width: 2 * irisR, height: 2 * irisR)),
                         with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 0.20, green: 0.45, blue: 0.70).opacity(0.85),
                                Color(red: 0.30, green: 0.55, blue: 0.78).opacity(0.65),
                                Color(red: 0.40, green: 0.65, blue: 0.85).opacity(0.40)
                            ]),
                            center: CGPoint(x: eyeCx, y: eyeCy),
                            startRadius: 0,
                            endRadius: irisR))
                // Pupil — solid black disc, dilates with `pupilR`.
                ctx.fill(Path(ellipseIn: CGRect(x: eyeCx - pupilR, y: eyeCy - pupilR, width: 2 * pupilR, height: 2 * pupilR)),
                         with: .color(.black.opacity(0.95)))
                // Catchlight — tiny white spot offset toward upper-right of pupil.
                let catchR: CGFloat = pupilR * 0.35
                let catchOffset = pupilR * 0.4
                ctx.fill(Path(ellipseIn: CGRect(x: eyeCx + catchOffset - catchR, y: eyeCy - catchOffset - catchR, width: 2 * catchR, height: 2 * catchR)),
                         with: .color(.white.opacity(0.85)))

                // Blink — a dark horizontal lid sweeps down over the iris.
                if blink > 0.01 {
                    let lidHeight = 2 * irisR * CGFloat(blink)
                    let lidRect = CGRect(x: eyeCx - irisR, y: eyeCy - irisR, width: 2 * irisR, height: lidHeight)
                    ctx.fill(Path(lidRect),
                             with: .color(Color(red: 0.18, green: 0.14, blue: 0.10).opacity(0.95)))
                }
            }
        }
        .task { await runBlinkLoop() }
    }

    // Schedules a blink (horizontal lid sweep down then up) every 3–6
    // seconds. The blink itself is fast (~250ms total) so it reads as natural.
    private func runBlinkLoop() async {
        while !Task.isCancelled {
            let waitNs = UInt64.random(in: 3_000_000_000 ... 6_000_000_000)
            try? await Task.sleep(nanoseconds: waitNs)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.10)) { blink = 1.0 }
            try? await Task.sleep(nanoseconds: 100_000_000)
            withAnimation(.easeOut(duration: 0.15)) { blink = 0 }
        }
    }
}
