import SwiftUI
import UIKit

enum ReadEditorTextViewFactory {
    static func makeTextView() -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        precondition(
            textView.textLayoutManager != nil,
            "TextKit 2 invariant violated: read editor must use UITextView with a textLayoutManager"
        )
        return textView
    }
}

struct TextKitAttributedTextEditor: UIViewRepresentable {
    @Binding var text: String
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double

    func makeUIView(context: Context) -> UITextView {
        let textView = ReadEditorTextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0

        applyTypography(to: textView, text: text)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let style = TypographyStyle(textSize: textSize, lineSpacing: lineSpacing, kerning: kerning)

        if context.coordinator.lastAppliedStyle != style || uiView.text != text {
            let selectedRange = uiView.selectedRange
            applyTypography(to: uiView, text: text)
            if selectedRange.location <= uiView.text.utf16.count {
                uiView.selectedRange = selectedRange
            }
            context.coordinator.lastAppliedStyle = style
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

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

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        var lastAppliedStyle: TypographyStyle?

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }

    private struct TypographyStyle: Equatable {
        let textSize: Double
        let lineSpacing: Double
        let kerning: Double
    }
}

struct TextKitAttributedTextPreview: UIViewRepresentable {
    let text: String
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double

    func makeUIView(context: Context) -> UITextView {
        let textView = ReadEditorTextViewFactory.makeTextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        applyTypography(to: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        applyTypography(to: uiView)
    }

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