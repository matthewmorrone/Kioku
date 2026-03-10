import SwiftUI
import UIKit

// Bridges a TextKit 2-backed editable text view into SwiftUI.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    let isLineWrappingEnabled: Bool
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isVisualEnhancementsEnabled: Bool
    let isColorAlternationEnabled: Bool
    let isHighlightUnknownEnabled: Bool
    let segmenter: Segmenter
    let isEditMode: Bool
    let externalContentOffsetY: CGFloat
    let onScrollOffsetYChanged: (CGFloat) -> Void
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double

    // Builds the on-screen editable text component used in ReadView.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.layoutManager.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = false
        textView.keyboardDismissMode = .interactive
        textView.isEditable = isEditMode
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        configureWrapping(for: textView)
        let pinchRecognizer = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(RichTextEditorCoordinator.handlePinch(_:)))
        pinchRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(pinchRecognizer)

        applyTypography(to: textView, text: text)
        return textView
    }

    // Refreshes the visible editor typography while keeping cursor placement stable.
    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.isEditable = isEditMode
        uiView.isSelectable = true
        context.coordinator.configureSegmentationRanges(segmentationRanges, in: text)
        configureWrapping(for: uiView)
        let needsStyleUpdate = true

        if needsStyleUpdate || uiView.text != text {
            let selectedRange = uiView.selectedRange
            applyTypography(to: uiView, text: text)
            if selectedRange.location <= uiView.text.utf16.count {
                uiView.selectedRange = selectedRange
            }
        }

        context.coordinator.onScrollOffsetYChanged = onScrollOffsetYChanged
        context.coordinator.applyExternalScrollIfNeeded(to: uiView, targetOffsetY: externalContentOffsetY)
    }

    // Connects the on-screen editor callbacks back to SwiftUI state.
    func makeCoordinator() -> RichTextEditorCoordinator {
        RichTextEditorCoordinator(text: $text, textSize: $textSize, onScrollOffsetYChanged: onScrollOffsetYChanged)
    }

    // Applies font, kerning, and paragraph spacing to both content and typing attributes.
    private func applyTypography(to textView: UITextView, text: String) {
        let font = UIFont.systemFont(ofSize: textSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing + (font.lineHeight * 0.5)
        paragraphStyle.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: kerning,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label,
        ]

        let attributedText = NSMutableAttributedString(string: text, attributes: baseAttributes)
        guard !isEditMode && isVisualEnhancementsEnabled else {
            textView.attributedText = attributedText
            textView.typingAttributes = baseAttributes
            return
        }

        let evenSegmentForeground = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemOrange : .systemRed
        }
        let oddSegmentForeground = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo
        }
        let unknownSegmentForeground = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemYellow : .systemOrange
        }
        let furiganaAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(textSize * 0.5, 8)),
            .kern: 0,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.secondaryLabel,
        ]
        var colorAlternationIndex = 0
        var furiganaInsertions: [(index: Int, text: String)] = []

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

            // Highlights unknown tokens only when alternation is active; otherwise keep default foreground styling.
            if isHighlightUnknownEnabled && isColorAlternationEnabled && !isTokenInDictionary(segmentText) {
                attributedText.addAttribute(.foregroundColor, value: unknownSegmentForeground, range: nsRange)
            } else if isColorAlternationEnabled {
                if colorAlternationIndex.isMultiple(of: 2) {
                    attributedText.addAttribute(.foregroundColor, value: evenSegmentForeground, range: nsRange)
                } else {
                    attributedText.addAttribute(.foregroundColor, value: oddSegmentForeground, range: nsRange)
                }
            }

            // Queues inline furigana text for segments when a reading is available.
            if let furigana = furiganaBySegmentLocation[nsRange.location] {
                furiganaInsertions.append((index: nsRange.location + nsRange.length, text: "（\(furigana)）"))
            }

            colorAlternationIndex += 1
        }

        // Inserts furigana in reverse order so earlier indices remain stable while mutating the string.
        for insertion in furiganaInsertions.sorted(by: { $0.index > $1.index }) {
            let annotation = NSAttributedString(string: insertion.text, attributes: furiganaAttributes)
            attributedText.insert(annotation, at: insertion.index)
        }

        textView.attributedText = attributedText
        textView.typingAttributes = baseAttributes
    }

    // Keeps the editor text container in wrapped or horizontal-scroll layout based on the display option.
    private func configureWrapping(for textView: UITextView) {
        let contentInsets = textView.textContainerInset
        let availableWidth = max(
            textView.bounds.width - contentInsets.left - contentInsets.right,
            0
        )
        textView.textContainer.widthTracksTextView = isLineWrappingEnabled
        textView.textContainer.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping
        textView.textContainer.size = CGSize(
            width: isLineWrappingEnabled ? availableWidth : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    // Identifies ranges that should not affect token color parity (spacing and punctuation only).
    private func shouldIgnoreSegmentForAlternation(_ segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }

    // Checks whether a token resolves through the segmenter's trie plus deinflection path.
    private func isTokenInDictionary(_ surface: String) -> Bool {
        segmenter.resolvesSurface(surface)
    }
}
