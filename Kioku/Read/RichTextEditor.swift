import SwiftUI
import UIKit

// Bridges a TextKit 2-backed editable text view into SwiftUI.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double

    // Builds the on-screen editable text component used in ReadView.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0

        applyTypography(to: textView, text: text)
        return textView
    }

    // Refreshes the visible editor typography while keeping cursor placement stable.
    func updateUIView(_ uiView: UITextView, context: Context) {
        let style = (textSize: textSize, lineSpacing: lineSpacing, kerning: kerning)
        let needsStyleUpdate: Bool

        if let lastAppliedStyle = context.coordinator.lastAppliedStyle {
            needsStyleUpdate = lastAppliedStyle != style
        } else {
            needsStyleUpdate = true
        }

        if needsStyleUpdate || uiView.text != text {
            let selectedRange = uiView.selectedRange
            applyTypography(to: uiView, text: text)
            if selectedRange.location <= uiView.text.utf16.count {
                uiView.selectedRange = selectedRange
            }
            context.coordinator.lastAppliedStyle = style
        }
    }

    // Connects the on-screen editor callbacks back to SwiftUI state.
    func makeCoordinator() -> RichTextEditorCoordinator {
        RichTextEditorCoordinator(text: $text)
    }

    // Applies font, kerning, and paragraph spacing to both content and typing attributes.
    private func applyTypography(to textView: UITextView, text: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: textSize),
            .kern: kerning,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label,
        ]

        textView.attributedText = NSAttributedString(string: text, attributes: attributes)
        textView.typingAttributes = attributes
    }
}
