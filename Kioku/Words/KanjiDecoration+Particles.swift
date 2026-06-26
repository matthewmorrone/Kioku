import SwiftUI
import UIKit

// SwiftUI bridge to CAEmitterLayer for high-density particle effects. SwiftUI Canvas
// is fine for a dozen primitives per frame but starts hurting at hundreds of moving
// particles — at which point CAEmitterLayer (hardware-accelerated, designed for this
// exact job since 2011) is the right tool. Wrapped in UIViewRepresentable so the
// SwiftUI decoration views can compose it like any other view.
struct KanjiParticleEmitter: UIViewRepresentable {
    let kind: KanjiParticleKind

    // Constructs the host UIView with its CAEmitterLayer already configured for `kind`.
    // Disabled hit testing so the emitter never steals taps from underlying content.
    func makeUIView(context: Context) -> KanjiParticleEmitterHostView {
        let view = KanjiParticleEmitterHostView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.configure(kind: kind)
        return view
    }

    // No dynamic config changes today — each decoration locks its kind at view creation.
    // updateUIView is a required protocol stub that intentionally does nothing.
    func updateUIView(_ uiView: KanjiParticleEmitterHostView, context: Context) {}
}

// Host UIView for the emitter layer. Owns layout — re-centers the emitter on bounds
// changes so the particle field tracks the host's size (matters at sheet detent
// transitions and on device rotation).
final class KanjiParticleEmitterHostView: UIView {
    private var emitter: CAEmitterLayer?
    private var kind: KanjiParticleKind?

    // Installs the emitter layer for `kind`. Called from makeUIView; rebuilds the
    // layer if the kind changes (currently unused — kind is set once per view).
    func configure(kind: KanjiParticleKind) {
        self.kind = kind
        emitter?.removeFromSuperlayer()
        let layer = CAEmitterLayer()
        layer.frame = bounds
        kind.configure(layer: layer, bounds: bounds)
        self.layer.addSublayer(layer)
        emitter = layer
    }

    // Keeps the emitter's frame + position in sync with the host's bounds after
    // layout. Important for sheet detent changes (medium → large) and rotation.
    override func layoutSubviews() {
        super.layoutSubviews()
        emitter?.frame = bounds
        if let kind { kind.updatePosition(layer: emitter!, bounds: bounds) }
    }
}

// Each KanjiParticleKind owns one CAEmitterLayer + CAEmitterCell configuration.
// Cached particle CGImages live in a static dictionary keyed by kind so the
// drawing cost is paid once per kind across the app's lifetime.
enum KanjiParticleKind {
    case rain
    case snow
    case fire

    // Builds the per-kind emitter layer config (position, shape, render mode) and
    // installs the cell(s). Some kinds use multiple cells (rain has main streaks
    // plus splashes at the bottom) for layered motion.
    func configure(layer: CAEmitterLayer, bounds: CGRect) {
        layer.emitterShape = .line
        layer.renderMode = renderMode
        updatePosition(layer: layer, bounds: bounds)
        layer.emitterCells = makeCells()
    }

    // Re-positions the emitter line for the kind. Rain/snow emit just above the
    // top edge so particles cross the visible area; fire emits at the bottom edge
    // so flames rise into the visible area.
    func updatePosition(layer: CAEmitterLayer, bounds: CGRect) {
        switch self {
        case .rain, .snow:
            layer.emitterPosition = CGPoint(x: bounds.midX, y: -60)
            layer.emitterSize = CGSize(width: bounds.width + 120, height: 1)
        case .fire:
            layer.emitterPosition = CGPoint(x: bounds.midX, y: bounds.height + 10)
            layer.emitterSize = CGSize(width: bounds.width * 0.85, height: 1)
        }
    }

    // Builds the cell(s) for this kind. Most kinds have one cell; rain layers in
    // a second "near rain" cell at a different scale + speed for a parallax sense
    // of depth (close streaks fall fast and big, far streaks fall slower and small).
    func makeCells() -> [CAEmitterCell] {
        switch self {
        case .rain:
            return [makeRainCell(near: false), makeRainCell(near: true)]
        case .snow:
            return [makeSnowCell()]
        case .fire:
            return [makeFireCell()]
        }
    }

    // Rain particles. Two passes (near and far) use a teardrop image — a round
    // drop with a fading tail at the trailing edge — so each particle reads as an
    // individual falling water droplet, not a streak. Slower velocity than the
    // streak version (so drops are visible falling, not a continuous band), but
    // higher birth rate to keep the field dense.
    private func makeRainCell(near: Bool) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = ParticleImage.teardrop(width: near ? 12 : 8, height: near ? 22 : 16)
        cell.birthRate = near ? 35 : 95
        cell.lifetime = near ? 2.5 : 3.5
        cell.lifetimeRange = 0.4
        cell.velocity = near ? 700 : 480
        cell.velocityRange = 90
        cell.emissionLongitude = .pi / 2 + 0.06
        cell.emissionRange = 0.04
        cell.scale = near ? 1.0 : 0.75
        cell.scaleRange = 0.35
        cell.alphaRange = 0.25
        cell.color = UIColor(red: 0.70, green: 0.84, blue: 1.0, alpha: near ? 0.95 : 0.75).cgColor
        return cell
    }

    // Snow particles. 6-point crystal shape (built by ParticleImage.snowflake) at
    // varied scales, slow vertical descent with wide sideways drift, gentle spin
    // so each flake reads as rotating in the air.
    private func makeSnowCell() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = ParticleImage.snowflake(size: 14)
        cell.birthRate = 55
        cell.lifetime = 11.0
        cell.lifetimeRange = 2.5
        cell.velocity = 45
        cell.velocityRange = 28
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = .pi / 3
        cell.spin = 0.5
        cell.spinRange = 1.4
        cell.scale = 0.55
        cell.scaleRange = 0.7
        cell.alphaRange = 0.45
        cell.color = UIColor(white: 1.0, alpha: 0.95).cgColor
        return cell
    }

    // Fire particles. Longer lifetime + stronger upward buoyancy so flames carry
    // most of the way up the sheet; reduced scaleSpeed so they stay big enough to
    // read as fire rather than receding pixels. Wider emission range gives flame
    // edges that lick outward like a real campfire.
    private func makeFireCell() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = ParticleImage.softDot(radius: 22)
        cell.birthRate = 150
        cell.lifetime = 3.6
        cell.lifetimeRange = 0.8
        cell.velocity = 260
        cell.velocityRange = 80
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 6
        cell.yAcceleration = -120
        cell.scale = 1.2
        cell.scaleRange = 0.6
        cell.scaleSpeed = -0.18
        cell.alphaSpeed = -0.28
        cell.color = UIColor(red: 1.0, green: 0.5, blue: 0.15, alpha: 1.0).cgColor
        return cell
    }

    // Render mode controls particle blending. Additive for fire so overlapping
    // flames sum to a hot glow; unordered (default) for rain/snow where overlap
    // shouldn't lighten.
    private var renderMode: CAEmitterLayerRenderMode {
        switch self {
        case .fire: return .additive
        case .rain, .snow: return .unordered
        }
    }
}

// CGImage builders for particle contents. Soft gradients give particles a glow
// without needing image assets shipped in the bundle — each is drawn once per
// kind via UIGraphicsImageRenderer and cached.
enum ParticleImage {
    // Vertical gradient streak — for rain. Transparent → white → transparent so
    // the streak has soft top/bottom edges and reads as falling water rather than
    // a hard tick. The emitter tints it via cell.color.
    static func streak(length: CGFloat, width: CGFloat) -> CGImage {
        let size = CGSize(width: width, height: length)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray,
                                      locations: [0, 0.5, 1])!
            cg.drawLinearGradient(gradient,
                                  start: .zero,
                                  end: CGPoint(x: 0, y: length),
                                  options: [])
        }
        return img.cgImage!
    }

    // Teardrop — round drop at the bottom, fading tail at the top. Drawn pointy-
    // side-up so when the cell falls downward, the rounded "head" leads and the
    // tail trails behind it (classic falling-droplet silhouette with motion blur).
    // Solid white interior — the emitter cell tints it via cell.color.
    static func teardrop(width: CGFloat, height: CGFloat) -> CGImage {
        let canvas = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let path = UIBezierPath()
            let halfW = width / 2
            // Tip at top (pixel y=0), round bottom (pixel y=height).
            path.move(to: CGPoint(x: halfW, y: 0))
            path.addQuadCurve(to: CGPoint(x: width, y: height * 0.62),
                              controlPoint: CGPoint(x: width * 0.85, y: height * 0.30))
            path.addArc(withCenter: CGPoint(x: halfW, y: height * 0.62),
                        radius: halfW,
                        startAngle: 0,
                        endAngle: .pi,
                        clockwise: true)
            path.addQuadCurve(to: CGPoint(x: halfW, y: 0),
                              controlPoint: CGPoint(x: width * 0.15, y: height * 0.30))
            path.close()

            cg.addPath(path.cgPath)
            cg.clip()

            // Vertical gradient — transparent at the tail (top), opaque at the head.
            let colors = [
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.withAlphaComponent(0.4).cgColor,
                UIColor.white.cgColor
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray,
                                      locations: [0, 0.55, 1])!
            cg.drawLinearGradient(gradient,
                                  start: .zero,
                                  end: CGPoint(x: 0, y: height),
                                  options: [])
        }
        return img.cgImage!
    }

    // Six-armed snowflake — three stroked lines crossing at 60° angles, plus tiny
    // branches at each arm's tip for the classic dendritic shape. Cell.color tints
    // the whole image (so the cell stays white-ish on top of the kanji card).
    static func snowflake(size: CGFloat) -> CGImage {
        let canvas = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(max(1.0, size * 0.07))
            cg.setLineCap(.round)
            let c = CGPoint(x: size / 2, y: size / 2)
            let armLen = size / 2 - max(1.0, size * 0.07)
            for i in 0..<3 {
                let angle = .pi / 3 * Double(i)
                let dx = CGFloat(cos(angle)) * armLen
                let dy = CGFloat(sin(angle)) * armLen
                cg.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                cg.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
            }
            cg.strokePath()
            // Small branches near the tips — give the dendritic look without too much
            // visual noise at small render sizes.
            cg.setLineWidth(max(0.7, size * 0.05))
            let branchLen = armLen * 0.28
            let branchOffset = armLen * 0.6
            for i in 0..<6 {
                let angle = .pi / 3 * Double(i)
                let dx = CGFloat(cos(angle))
                let dy = CGFloat(sin(angle))
                let tip = CGPoint(x: c.x + dx * branchOffset, y: c.y + dy * branchOffset)
                for branchAngleDelta in [-Double.pi / 4, Double.pi / 4] {
                    let bAngle = angle + branchAngleDelta
                    cg.move(to: tip)
                    cg.addLine(to: CGPoint(x: tip.x + CGFloat(cos(bAngle)) * branchLen,
                                           y: tip.y + CGFloat(sin(bAngle)) * branchLen))
                }
            }
            cg.strokePath()
        }
        return img.cgImage!
    }

    // Radial gradient dot — for snow, fire, sparks. Solid center fading to clear
    // edge. Used as a generic soft particle shape; tint comes from cell.color.
    static func softDot(radius: CGFloat) -> CGImage {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor.white.cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray,
                                      locations: [0, 1])!
            cg.drawRadialGradient(gradient,
                                  startCenter: CGPoint(x: radius, y: radius),
                                  startRadius: 0,
                                  endCenter: CGPoint(x: radius, y: radius),
                                  endRadius: radius,
                                  options: [])
        }
        return img.cgImage!
    }
}

// MARK: - 雨 Rain

// Owned by KanjiDecoration.view(for:) — registered for the literal 雨.
struct RainDecoration: View {
    // Dense rain via CAEmitterLayer — ~240 particles per second, each a soft
    // vertical streak with edge-faded alpha. Blue-white tint sits at the cool
    // end of the palette so it reads as water against any sheet background.
    var body: some View {
        KanjiParticleEmitter(kind: .rain)
    }
}

// MARK: - 雪 Snow

// Owned by KanjiDecoration.view(for:) — registered for the literal 雪.
struct SnowDecoration: View {
    // Slow snowfall via CAEmitterLayer — ~35 flakes per second with 9s lifetimes
    // so a thick field accumulates and stays visible. Wide emissionRange (±45°)
    // gives flakes natural-feeling drift without needing per-flake oscillation.
    // Spin animates each flake's rotation as it falls.
    var body: some View {
        KanjiParticleEmitter(kind: .snow)
    }
}

// MARK: - 火 Fire

// Owned by KanjiDecoration.view(for:) — registered for the literal 火.
struct FireDecoration: View {
    // Flames rise from the bottom edge with additive blending so overlapping
    // particles sum to a hot glow. scaleSpeed = -0.35 shrinks each flame as it
    // rises, mimicking heat dissipation; alphaSpeed = -0.6 fades it out before
    // it reaches the top.
    var body: some View {
        KanjiParticleEmitter(kind: .fire)
    }
}
