import SwiftUI
import PencilKit
import Combine
import Zinnia_Swift

extension Notification.Name {
    // Posted by JapaneseInputTextField's accessory ✕ when the active mode is handwriting, so the
    // hosted HandwritingInputView can wipe its drawing without the host needing direct access to
    // the view's @State.
    static let kiokuHandwritingClearRequested = Notification.Name("kiokuHandwritingClearRequested")
}

// Handwriting input sheet. User draws a character with a finger or Apple Pencil; strokes are
// passed to the bundled Tegaki/Zinnia Japanese model and top candidates appear as tappable chips.
// Owned by WordsView; surfaced either as a modal sheet (overflow menu) or as the inputView of
// JapaneseInputTextField (the ✋ toggle). Tapping a candidate calls onEmit so the host appends
// it to the destination text; the sheet stays up for the next character. The chrome parameter
// chooses whether to wrap in a NavigationStack with title + Close — modal sheets want it; inline
// inputView hosts don't (there's nothing to dismiss, and the chrome wastes keyboard-area space).
struct HandwritingInputView: View {
    enum Chrome { case navigation, none }

    let onEmit: (String) -> Void
    // Removes the last character from the destination text field — backspace for a wrong pick.
    var onDeleteBackward: (() -> Void)? = nil
    var chrome: Chrome = .navigation

    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = CGSize(width: 256, height: 256)
    @State private var results: [Recognizer.Result] = []
    @State private var recognizer: Recognizer?
    @State private var initError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch chrome {
        case .navigation:
            NavigationStack {
                coreBody
                    .navigationTitle("Handwriting")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close") { dismiss() }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                onDeleteBackward?()
                            } label: {
                                Image(systemName: "delete.left")
                            }
                            .accessibilityLabel("Delete last character")
                        }
                    }
            }
        case .none:
            coreBody
                .ignoresSafeArea(.all, edges: .top)
        }
    }

    // The shared inner body — strip + canvas + action bar — used in both modal and inline modes.
    // Lifecycle hooks (recognition task + onChange-driven recognize) live here so they run in
    // either presentation context. The outer frame with .top alignment ensures the VStack
    // anchors to the top of available space instead of centering vertically (SwiftUI's default
    // behavior when content's natural size is smaller than the proposed height).
    private var coreBody: some View {
        VStack(spacing: 0) {
            candidateStrip
            Divider()
            canvas
                .background(Color(.secondarySystemBackground))
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { loadRecognizer() }
        // Auto-recognize after every stroke: PencilKit's drawingDidChange fires once per
        // completed stroke, and Zinnia classification is fast enough to run inline, so
        // candidates refresh live as the character takes shape — no Recognize button.
        .onChange(of: drawing) {
            if drawing.strokes.isEmpty {
                results = []
            } else {
                recognize()
            }
        }
        // Inline-mode ✕ accessory clears the canvas via this notification — keeps the host
        // (JapaneseInputTextField's Coordinator) out of SwiftUI's state graph.
        .onReceive(NotificationCenter.default.publisher(for: .kiokuHandwritingClearRequested)) { _ in
            drawing = PKDrawing()
            results = []
        }
    }

    // Top strip: tappable kanji candidates. Renders an empty band before any strokes are drawn
    // (no placeholder text — the canvas itself is the affordance), the "Recognizing…" status
    // briefly while classification runs, or the candidate chips once results land.
    @ViewBuilder
    private var candidateStrip: some View {
        Group {
            if let err = initError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
            } else if drawing.strokes.isEmpty {
                // Fixed-height spacer that mirrors the strip's natural size when populated, so the
                // canvas doesn't visibly shrink the moment recognition results land.
                Color.clear.frame(height: 64)
            } else if results.isEmpty {
                Text("Recognizing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(results.prefix(20).enumerated()), id: \.offset) { _, candidate in
                            Button {
                                // Append straight into the destination text field and clear the
                                // canvas for the next character. Host owns the append semantics.
                                onEmit(candidate.character)
                                drawing = PKDrawing()
                                results = []
                            } label: {
                                Text(candidate.character)
                                    .font(.title)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(.tertiarySystemBackground))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(candidate.character)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(height: 64)
            }
        }
        .background(Color(.systemBackground))
    }

    // PencilKit drawing canvas. Lays out at a square aspect so canvasSize matches the strokes
    // we hand to Zinnia (whose canvasSize defines the bounding box of the input character).
    @ViewBuilder
    private var canvas: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                PencilKitCanvas(drawing: $drawing, canvasSize: $canvasSize)
                    .frame(width: side, height: side)
                    .background(Color(.systemBackground))
                    .overlay(
                        // Subtle box hint so the user knows the drawable area.
                        Rectangle()
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // Bottom action bar — Clear wipes the drawing. Only rendered in modal (.navigation) mode;
    // inline mode delegates clearing to the JapaneseInputTextField accessory ✕ button, which
    // posts kiokuHandwritingClearRequested.
    @ViewBuilder
    private var actionBar: some View {
        if chrome == .navigation {
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    drawing = PKDrawing()
                    results = []
                } label: {
                    Label("Clear", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(drawing.strokes.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // Loads the bundled Tegaki Japanese model once. Surfaces a user-facing error if the file is
    // missing — typically because the dev didn't drop handwriting-ja.model into Resources/.
    private func loadRecognizer() {
        guard let url = Bundle.main.url(forResource: "handwriting-ja", withExtension: "model") else {
            initError = "Handwriting model not found in app bundle. See data_manifest.json for the Tegaki download command."
            return
        }
        do {
            recognizer = try Recognizer(
                modelURL: url,
                canvasSize: Recognizer.Size(cgSize: canvasSize)
            )
        } catch {
            initError = "Could not load handwriting model: \(error.localizedDescription)"
        }
    }

    // Converts the PKDrawing into Zinnia strokes (lossy down-sampling preserves shape but drops
    // the fine bezier detail PencilKit captures, which Zinnia doesn't use), then classifies.
    private func recognize() {
        guard let recognizer else { return }
        recognizer.canvasSize = Recognizer.Size(cgSize: canvasSize)

        var zinniaStrokes: [Stroke] = []
        for pkStroke in drawing.strokes {
            var stroke = Stroke()
            // PKStrokePath sampling: stride through interpolation parameters to get ~30 points
            // per stroke regardless of stroke length. Anything denser is wasted on Zinnia.
            let path = pkStroke.path
            let count = path.count
            guard count > 0 else { continue }
            let sampleCount = min(max(count, 4), 30)
            for i in 0..<sampleCount {
                let t = Double(i) / Double(max(sampleCount - 1, 1))
                let idx = Int(Double(count - 1) * t)
                let point = path.interpolatedLocation(at: CGFloat(idx))
                stroke.add(point: point)
            }
            zinniaStrokes.append(stroke)
        }

        results = recognizer.classify(strokes: zinniaStrokes, maxResults: 20)
    }
}

// SwiftUI bridge to PKCanvasView. The drawing binding feeds back stroke changes to the parent;
// canvasSize publishes the actual rendered size so the Zinnia recognizer can scale strokes.
struct PencilKitCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var canvasSize: CGSize

    // Builds the canvas view, enables finger input (PencilKit defaults to Pencil-only on iPad),
    // and wires the coordinator as the delegate so we get drawingDidChange callbacks. Pen color
    // is a hardcoded saturated blue — dynamic .label / colorScheme detection is unreliable inside
    // the keyboard window (UIKit and SwiftUI trait propagation can disagree, leaving strokes
    // invisible against the matching-tone background). systemBlue stays high-contrast on both
    // light and dark canvases.
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.pen, color: .systemBlue, width: 10)
        return canvas
    }

    // Sync external drawing changes (e.g. Clear button) into the canvas and publish current bounds
    // for the recognizer's canvasSize. PKDrawing equality is reference-based here, which made a
    // freshly-allocated empty PKDrawing() (from Clear) look "different" enough to assign but the
    // assignment was being optimized away in some PencilKit builds — compare stroke counts
    // explicitly so a clear-to-empty always triggers a re-render.
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing.strokes.count != drawing.strokes.count {
            uiView.drawing = drawing
        }
        DispatchQueue.main.async {
            if canvasSize != uiView.bounds.size {
                canvasSize = uiView.bounds.size
            }
        }
    }

    // Standard Coordinator → PKCanvasViewDelegate wrapper that funnels drawingDidChange back
    // to the SwiftUI parent through the drawing binding.
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilKitCanvas
        init(parent: PencilKitCanvas) { self.parent = parent }
        // Propagates strokes upward so SwiftUI views can react to "Recognize" being newly enabled.
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
