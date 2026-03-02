import SwiftUI
import UIKit

// Bridges a TextKit 2-backed read-only preview text view into SwiftUI.
struct RichTextPreview: UIViewRepresentable {
    let text: String
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double

    // Builds the on-screen read-only preview used in Settings.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        applyTypography(to: textView)
        return textView
    }

    // Refreshes visible preview styling when slider values change.
    func updateUIView(_ uiView: UITextView, context: Context) {
        applyTypography(to: uiView)
    }

    // Applies paragraph and character attributes to preview content.
    private func applyTypography(to textView: UITextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: textSize),
            .kern: kerning,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label,
        ]

        textView.attributedText = NSAttributedString(string: text, attributes: attributes)
    }
}
