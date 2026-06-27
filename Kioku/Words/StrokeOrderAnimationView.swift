import SwiftUI

// Renders KanjiVG stroke data for one character as a draw-on animation. Each stroke fills in
// sequentially with a brief pause between strokes; tapping the canvas restarts the animation.
// Owned by KanjiDetailView; replaces the hero glyph when stroke data is available.
struct StrokeOrderAnimationView: View {
    let strokes: [DictionaryStore.KanjiStrokeRecord]

    // Tracks the index of the "active" stroke. Lower indices are drawn fully; the active
    // stroke draws from 0..1; higher indices are not yet shown.
    @State private var activeIndex: Int = 0
    @State private var activeProgress: CGFloat = 0
    @State private var generation: Int = 0

    // KanjiVG paths live in a 109×109 coordinate space (the original SVG viewBox).
    private let svgCanvasSize: CGFloat = 109

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let scale = side / svgCanvasSize

            // ONE coordinate pipeline: every path inside this ZStack (grid + each stroke)
            // is authored in the native 109-unit KanjiVG space, and a single .scaleEffect
            // below maps the entire composition to pt. The previous per-leaf scaling pattern
            // worked only as long as every leaf remembered to scale — the gridOverlay didn't,
            // so its 109-unit content sat at the top-left of a side×side frame while the
            // strokes filled it, and the kanji visibly drifted off the grid's center cross.
            // A uniform single-transform pipeline makes that bug class structurally impossible.
            ZStack(alignment: .topLeading) {
                // Background grid for visual reference — center cross + outer box, faint.
                gridOverlay
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

                ForEach(Array(strokes.enumerated()), id: \.offset) { idx, stroke in
                    if let cg = SVGPathParser.cgPath(from: stroke.pathD) {
                        // Each stroke renders fully when its index is past, partially when it's
                        // the active stroke, not at all when it's still upcoming.
                        let trimTo: CGFloat = idx < activeIndex ? 1
                                            : (idx == activeIndex ? activeProgress : 0)
                        // Shape.trim(from:to:) — the ANIMATABLE form. Previously used
                        // Path.trimmedPath(from:to:) which returns a static Path snapshot
                        // SwiftUI's animation system can't interpolate, so each stroke
                        // appeared all-at-once instead of drawing on.
                        Path(cg)
                            .trim(from: 0, to: trimTo)
                            .stroke(strokeColor(for: idx),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: svgCanvasSize, height: svgCanvasSize, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: side, height: side, alignment: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture { restart() }
            .onAppear { restart() }
            .accessibilityLabel("Stroke order animation — tap to replay")
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // Recent strokes (just drawn) glow a touch brighter; earlier strokes settle to plain ink.
    private func strokeColor(for idx: Int) -> Color {
        if idx == activeIndex { return .accentColor }
        return .primary
    }

    // Subtle 8×8 light grid + outer border for visual anchoring while animation plays.
    private var gridOverlay: Path {
        var p = Path()
        let side: CGFloat = 1
        p.addRect(CGRect(x: 0, y: 0, width: side, height: side).scaled(by: svgCanvasSize))
        p.move(to: CGPoint(x: 0, y: svgCanvasSize / 2))
        p.addLine(to: CGPoint(x: svgCanvasSize, y: svgCanvasSize / 2))
        p.move(to: CGPoint(x: svgCanvasSize / 2, y: 0))
        p.addLine(to: CGPoint(x: svgCanvasSize / 2, y: svgCanvasSize))
        return p
    }

    // Restarts the animation from stroke 0. Uses a `generation` counter so cancelled previous
    // tasks (from rapid retaps) discard their pending progress updates.
    private func restart() {
        guard strokes.isEmpty == false else { return }
        activeIndex = 0
        activeProgress = 0
        generation += 1
        let myGeneration = generation
        Task { @MainActor in
            for idx in 0..<strokes.count {
                guard myGeneration == generation else { return }
                activeIndex = idx
                activeProgress = 0
                // 0.65s draw + 0.25s pause = ~0.9s per stroke, slow enough to
                // actually watch the brush travel along each stroke.
                withAnimation(.easeInOut(duration: 0.65)) {
                    activeProgress = 1
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard myGeneration == generation else { return }
            }
            // After the last stroke, leave everything fully drawn (clamp activeIndex past end).
            activeIndex = strokes.count
        }
    }
}

// Minimal CGRect helper used only by the grid overlay.
private extension CGRect {
    // Scales the rect's origin and size uniformly by the given factor.
    func scaled(by factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}
