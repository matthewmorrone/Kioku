import SwiftUI
import UIKit

// Renders a word surface with per-kanji-run furigana drawn manually above each kanji run.
// The gap between furigana text and the base glyph is controlled by the `gap` parameter.
// Uses FuriganaView which draws furigana as an explicit overlay rather than CTRubyAnnotation,
// allowing uniform gap control across read view and inline contexts.
struct FuriganaLabel: UIViewRepresentable {
    let surface: String
    let reading: String
    let font: UIFont
    let gap: CGFloat
    var textColor: UIColor = .label
    // Per-UTF-16-offset colors local to `surface`. When provided, overrides textColor per segment.
    var segmentColors: [Int: UIColor] = [:]
    // Per-kanji-run readings keyed by run start character index. When non-empty, bypasses reading projection so every kanji run is guaranteed to show its furigana.
    var explicitRunReadings: [Int: String] = [:]

    // Creates the underlying FuriganaView with compression and hugging priorities set so SwiftUI respects its intrinsic height.
    func makeUIView(context: Context) -> FuriganaView {
        let view = FuriganaView()
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    // Pushes updated text, font, and color state into the underlying UIKit view when SwiftUI state changes.
    func updateUIView(_ view: FuriganaView, context: Context) {
        view.configure(surface: surface, reading: reading, font: font, gap: gap, textColor: textColor, segmentColors: segmentColors, explicitRunReadings: explicitRunReadings)
    }

    // Reports the view's natural size so SwiftUI can allocate the correct height.
    // When width is unspecified (InlineWrapLayout measuring chip size), returns the natural
    // single-line width so chips don't claim the full screen width and force line breaks.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FuriganaView, context: Context) -> CGSize? {
        if let width = proposal.width {
            return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        // No width constraint — return natural (single-line) dimensions.
        return uiView.naturalSize()
    }

}
