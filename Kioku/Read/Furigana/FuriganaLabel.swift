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

    func makeUIView(context: Context) -> FuriganaView {
        let view = FuriganaView()
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: FuriganaView, context: Context) {
        view.configure(surface: surface, reading: reading, font: font, gap: gap)
    }

    // Reports the view's natural size so SwiftUI can allocate the correct height.
    // Without this, fixedSize(vertical:) collapses UIViewRepresentable to zero height.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FuriganaView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.window?.screen.bounds.width ?? 390
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
