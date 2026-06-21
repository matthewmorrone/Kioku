import SwiftUI

// Direct-manipulation timing editor for ONE lyric line. Drag the green START / red END boundaries
// onto the audio; drag the white PLAYHEAD line (or tap) to scrub; one-finger drag on the empty
// waveform PANS the timeline; pinch to ZOOM the time span. Boundary drags commit once on release
// (onSetStart/onSetEnd) so
// dragging doesn't thrash the on-disk cue store. The visible window is line-derived by default and
// resets when the targeted line changes (lineID) — but pan/zoom persist while you work one line.
struct WaveformLineEditor: View {
    let envelope: WaveformEnvelope
    // Default (line-derived) window; used until the user pans/zooms, and again after a line switch.
    let windowStartMs: Int
    let windowEndMs: Int
    // Identifies the targeted line; a change resets pan/zoom to the default window for the new line.
    let lineID: Int
    let lineStartMs: Int
    let lineEndMs: Int
    let playheadMs: Int
    // Commit callbacks (fired once on release); onSeek fires on a tap.
    let onSetStart: (Int) -> Void
    let onSetEnd: (Int) -> Void
    let onSeek: (Int) -> Void

    private enum Mode { case start, end, seek, pan }
    @State private var mode: Mode? = nil
    @State private var dragMs: Int = 0
    // Current view window; nil → fall back to the passed default. Set by pan/zoom.
    @State private var viewStartMs: Int? = nil
    @State private var viewSpanMs: Int? = nil
    @State private var panAnchorMs: Int = 0       // view start captured when a pan begins
    @State private var pinchSpanMs: Int? = nil    // span captured when a pinch begins (nil = not pinching)
    @State private var pinchCenterMs: Int = 0     // time held fixed under a pinch

    private let grabThreshold: CGFloat = 24
    private let minSpanMs = 700

    private var defaultSpan: Int { max(1, windowEndMs - windowStartMs) }
    private var curStart: Int { viewStartMs ?? windowStartMs }
    private var curSpan: Int { viewSpanMs ?? defaultSpan }
    private var maxSpanMs: Int { max(defaultSpan, min(max(1, envelope.durationMs), 60_000)) }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = geo.size.height
            let vStart = curStart
            let vSpan = curSpan
            let span = CGFloat(max(1, vSpan))
            let xFor: (Int) -> CGFloat = { ms in CGFloat(ms - vStart) / span * w }
            let msFor: (CGFloat) -> Int = { x in vStart + Int((x / w) * span) }
            let liveStart = (mode == .start) ? dragMs : lineStartMs
            let liveEnd = (mode == .end) ? dragMs : lineEndMs
            let startX = xFor(liveStart)
            let endX = xFor(liveEnd)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))

                Canvas { ctx, size in
                    let mid = size.height / 2
                    var path = Path()
                    var x: CGFloat = 0
                    while x < size.width {
                        let ms = Double(vStart) + Double(x / size.width) * Double(vSpan)
                        let half = CGFloat(envelope.peak(atMs: ms)) * mid * 0.92
                        path.move(to: CGPoint(x: x, y: mid - max(0.5, half)))
                        path.addLine(to: CGPoint(x: x, y: mid + max(0.5, half)))
                        x += 1
                    }
                    ctx.stroke(path, with: .color(.secondary.opacity(0.9)), lineWidth: 1)
                }

                // Selected span shading between the two boundaries.
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: max(0, endX - startX), height: h)
                    .offset(x: startX)

                // Playhead.
                Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5, height: h)
                    .offset(x: xFor(playheadMs))

                boundary(color: .green, glyph: "S", x: startX, h: h)
                boundary(color: .red, glyph: "E", x: endX, h: h)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard pinchSpanMs == nil else { return }   // pinch owns the gesture
                        if mode == nil {
                            // Grab whichever target is under the touch: a boundary handle, the
                            // playhead (scrub), or — if none is close — the empty waveform (pan).
                            let dStart = abs(v.startLocation.x - startX)
                            let dEnd = abs(v.startLocation.x - endX)
                            let dPlay = abs(v.startLocation.x - xFor(playheadMs))
                            let dHandle = min(dStart, dEnd)
                            if dHandle <= grabThreshold && dHandle <= dPlay {
                                mode = dStart <= dEnd ? .start : .end
                            } else if dPlay <= grabThreshold {
                                mode = .seek
                            } else {
                                mode = .pan
                                panAnchorMs = vStart
                            }
                        }
                        switch mode {
                        case .start, .end:
                            dragMs = max(vStart, min(vStart + vSpan, msFor(v.location.x)))
                        case .seek:
                            onSeek(max(0, min(envelope.durationMs, msFor(v.location.x))))
                        case .pan:
                            let msPerPt = Double(vSpan) / Double(w)
                            viewStartMs = clampStart(panAnchorMs - Int(v.translation.width * msPerPt), span: vSpan)
                        case nil: break
                        }
                    }
                    .onEnded { v in
                        let ms = max(0, min(envelope.durationMs, msFor(v.location.x)))
                        switch mode {
                        case .start: onSetStart(ms)
                        case .end: onSetEnd(ms)
                        case .seek: onSeek(ms)
                        case .pan: if abs(v.translation.width) < 4 { onSeek(ms) }   // a tap, not a pan
                        case nil: break
                        }
                        mode = nil
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if pinchSpanMs == nil {
                            pinchSpanMs = vSpan
                            pinchCenterMs = vStart + vSpan / 2
                            mode = nil   // cancel any in-flight pan when a pinch takes over
                        }
                        let base = pinchSpanMs ?? vSpan
                        let newSpan = max(minSpanMs, min(maxSpanMs, Int(Double(base) / max(0.1, v.magnification))))
                        viewSpanMs = newSpan
                        viewStartMs = clampStart(pinchCenterMs - newSpan / 2, span: newSpan)
                    }
                    .onEnded { _ in pinchSpanMs = nil }
            )
            .onChange(of: lineID) { _, _ in
                viewStartMs = nil
                viewSpanMs = nil
            }
        }
    }

    // Clamps a view start so the [start, start+span] window stays inside the audio.
    private func clampStart(_ s: Int, span: Int) -> Int {
        max(0, min(s, max(0, envelope.durationMs - span)))
    }

    // One draggable boundary: a vertical bar with a labeled grab tab at the top.
    private func boundary(color: Color, glyph: String, x: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(color).frame(width: 2, height: h)
            Text(glyph)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(width: 14, alignment: .top)
        .offset(x: x - 7)
    }
}
