import SwiftUI
import UIKit

// Bridges a TextKit 2-backed editable text view into SwiftUI.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    let segmentationRanges: [Range<String.Index>]
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double

    // Builds the on-screen editable text component used in ReadView.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
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

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: textSize),
            .kern: kerning,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label,
        ]

        let attributedText = NSMutableAttributedString(string: text, attributes: baseAttributes)
        let evenSegmentForeground = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemOrange : .systemRed
        }
        let oddSegmentForeground = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo
        }
        var colorAlternationIndex = 0

        // Alternates foreground colors by segment index so token boundaries remain visually distinct.
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                continue
            }

            let segmentText = String(text[segmentRange])
            // Keeps spacing and punctuation neutral so they do not shift meaningful token alternation.
            if shouldIgnoreSegmentForAlternation(segmentText) {
                continue
            }

            if colorAlternationIndex.isMultiple(of: 2) {
                attributedText.addAttribute(.foregroundColor, value: evenSegmentForeground, range: nsRange)
            } else {
                attributedText.addAttribute(.foregroundColor, value: oddSegmentForeground, range: nsRange)
            }

            colorAlternationIndex += 1
        }

        textView.attributedText = attributedText
        textView.typingAttributes = baseAttributes
    }

    // Identifies ranges that should not affect token color parity (spacing and punctuation only).
    private func shouldIgnoreSegmentForAlternation(_ segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }
}
