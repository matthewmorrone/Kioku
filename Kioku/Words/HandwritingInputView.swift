import SwiftUI
import PencilKit
import Zinnia_Swift

// Handwriting input sheet. User draws a character with a finger or Apple Pencil; strokes are
// passed to the bundled Tegaki/Zinnia Japanese model and top candidates appear as tappable chips.
// Owned by WordsView; presented as a 2/3-height sheet from the toolbar pencil icon, so the
// search field stays visible above. Tapping a candidate appends it to the search field LIVE
// (the sheet stays up for the next character); the toolbar backspace removes the last one.
struct HandwritingInputView: View {
    let onSelectCharacter: (String) -> Void
    // Removes the last character from the destination text field — backspace for a wrong pick.
    var onDeleteBackward: (() -> Void)? = nil

    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = CGSize(width: 256, height: 256)
    @State private var results: [Recognizer.Result] = []
    @State private var recognizer: Recognizer?
    @State private var initError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                candidateStrip
                Divider()
                canvas
                    .background(Color(.secondarySystemBackground))
                actionBar
            }
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
        }
    }

    // Top strip: tappable kanji candidates, or status text when nothing has been drawn yet.
    @ViewBuilder
    private var candidateStrip: some View {
        Group {
            if let err = initError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 12)
            } else if results.isEmpty {
                Text(drawing.strokes.isEmpty
                     ? "Draw a character below."
                     : "Recognizing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(results.prefix(20).enumerated()), id: \.offset) { _, candidate in
                            Button {
                                // Append straight into the search field (visible above the
                                // 2/3-height sheet) and clear the canvas for the next character.
                                onSelectCharacter(candidate.character)
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
        .padding(16)
    }

    // Bottom action bar — Clear wipes the drawing. (Recognition runs automatically after every
    // stroke now, so the Recognize button is retired.)
    @ViewBuilder
    private var actionBar: some View {
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

            // Button {
            //     recognize()
            // } label: {
            //     Label("Recognize", systemImage: "wand.and.stars")
            //         .frame(maxWidth: .infinity)
            // }
            // .buttonStyle(.borderedProminent)
            // .disabled(drawing.strokes.isEmpty || recognizer == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
    // and wires the coordinator as the delegate so we get drawingDidChange callbacks.
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .label, width: 10)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        return canvas
    }

    // Sync external drawing changes (e.g. Clear button) into the canvas, and publish the
    // current bounds for the recognizer's canvasSize.
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
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
