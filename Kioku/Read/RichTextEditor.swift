import SwiftUI
import UIKit

// Bridges a TextKit 2-backed editable text view into SwiftUI.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var textSize: Double
    let segmentRanges: [Range<String.Index>]
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
        let pinchRecognizer = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(RichTextEditorCoordinator.handlePinch(_:)))
        pinchRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(pinchRecognizer)

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
        RichTextEditorCoordinator(text: $text, textSize: $textSize)
    }

    // Applies font, kerning, and paragraph spacing to both content and typing attributes.
    private func applyTypography(to textView: UITextView, text: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: textSize),
            .kern: kerning,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label,
        ]

        let attributedText = NSMutableAttributedString(string: text, attributes: attributes)
        let alternatingColors: [UIColor] = [
            .systemBlue,
            .systemRed,
            // .systemPurple,
            // .systemTeal,
            // .systemIndigo,
            // .systemOrange,
        ]
        var colorIndex = 0

        for range in segmentRanges {
            let segment = String(text[range])
            guard shouldCountForAlternatingColor(segment) else {
                continue
            }

            guard let nsRange = nsRange(from: range, in: text) else {
                continue
            }

            attributedText.addAttribute(
                .foregroundColor,
                value: alternatingColors[colorIndex % alternatingColors.count],
                range: nsRange
            )
            colorIndex += 1
        }

        textView.attributedText = attributedText
        textView.typingAttributes = attributes
    }

    // Determines whether a segment should advance alternating color parity.
    private func shouldCountForAlternatingColor(_ segment: String) -> Bool {
        guard !segment.isEmpty else {
            return false
        }

        for character in segment {
            if !ScriptClassifier.isBoundaryCharacter(character) {
                return true
            }
        }

        return false
    }

    // Converts a String.Index-based range into NSRange for attributed-text updates.
    private func nsRange(from range: Range<String.Index>, in text: String) -> NSRange? {
        guard
            let lowerBound = range.lowerBound.samePosition(in: text.utf16),
            let upperBound = range.upperBound.samePosition(in: text.utf16)
        else {
            return nil
        }

        let location = text.utf16.distance(from: text.utf16.startIndex, to: lowerBound)
        let length = text.utf16.distance(from: lowerBound, to: upperBound)
        return NSRange(location: location, length: length)
    }
}
