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
    let segmenter: any TextSegmenting
    let isEditMode: Bool
    let externalContentOffsetY: CGFloat
    let onScrollOffsetYChanged: (CGFloat) -> Void
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let furiganaGap: Double
    // Debug overlay flags — false in production use.
    let debugHeadwordLineBands: Bool
    let debugFuriganaLineBands: Bool

    // Builds the on-screen editable text component used in ReadView.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.delegate = context.coordinator
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

        let lineBandOverlay = LineBandOverlayView()
        lineBandOverlay.tag = 7_335
        textView.addSubview(lineBandOverlay)

        applyTypography(to: textView, text: text)
        context.coordinator.lastRenderedText = text
        context.coordinator.lastAppliedStyle = styleSignature
        return textView
    }

    // Refreshes the visible editor typography while keeping cursor placement stable.
    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.isEditable = isEditMode
        uiView.isSelectable = true
        context.coordinator.configureSegmentationRanges(isEditMode ? segmentationRanges : [], in: text)
        configureWrapping(for: uiView)
        let styleSignature = styleSignature
        let needsTextUpdate = context.coordinator.lastRenderedText != text
        let needsStyleUpdate = context.coordinator.lastAppliedStyle != styleSignature

        if needsStyleUpdate || needsTextUpdate {
            let selectedRange = uiView.selectedRange
            applyTypography(to: uiView, text: text)
            if selectedRange.location <= uiView.text.utf16.count {
                uiView.selectedRange = selectedRange
            }
            context.coordinator.lastRenderedText = text
            context.coordinator.lastAppliedStyle = styleSignature
        }

        context.coordinator.onScrollOffsetYChanged = onScrollOffsetYChanged
        context.coordinator.applyExternalScrollIfNeeded(to: uiView, targetOffsetY: externalContentOffsetY)

        guard let lineBandOverlay = uiView.viewWithTag(7_335) as? LineBandOverlayView else { return }
        applyLineBandOverlay(to: uiView, overlay: lineBandOverlay)
    }

    // Computes line band rects from the layout engine and pushes them to the overlay.
    // Uses the same caretRect + layoutFragmentFrame pipeline as the read-mode renderer.
    private func applyLineBandOverlay(to textView: UITextView, overlay: LineBandOverlayView) {
        let overlayFrame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(textView.contentSize.width, textView.bounds.width),
                height: max(textView.contentSize.height, textView.bounds.height)
            )
        )

        guard debugHeadwordLineBands || debugFuriganaLineBands,
              let tlm = textView.textLayoutManager,
              let tcm = tlm.textContentManager else {
            overlay.apply(
                overlayFrame: overlayFrame,
                headwordBandRects: [],
                furiganaLineBandRects: [],
                headwordBandsEnabled: false,
                furiganaLineBandsEnabled: false
            )
            return
        }

        let bodyFont = UIFont.systemFont(ofSize: textSize)
        let bandHeight = bodyFont.lineHeight
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)

        let docStart = tcm.documentRange.location
        var headwordRects: [CGRect] = []
        var furiganaRects: [CGRect] = []

        tlm.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let fragmentOffset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            for lineFragment in fragment.textLineFragments {
                let lineDocStart = fragmentOffset + lineFragment.characterRange.location
                guard let anchorPosition = textView.position(
                    from: textView.beginningOfDocument,
                    offset: lineDocStart
                ) else { continue }
                let caretR = textView.caretRect(for: anchorPosition)
                guard caretR.isNull == false,
                      caretR.isInfinite == false,
                      caretR.height > 0 else { continue }
                let textNS = textView.text as NSString
                let isBlankLine = lineDocStart < textNS.length
                    ? textNS.character(at: lineDocStart) == 0x000A
                    : true
                if debugHeadwordLineBands {
                    let bandY = isBlankLine ? caretR.minY + furiganaFont.lineHeight + CGFloat(lineSpacing) : caretR.minY
                    headwordRects.append(CGRect(
                        x: 0, y: bandY, width: overlayFrame.width, height: bandHeight
                    ))
                }
                if debugFuriganaLineBands && !isBlankLine {
                    furiganaRects.append(CGRect(
                        x: 0,
                        y: caretR.minY - furiganaFont.lineHeight - CGFloat(furiganaGap),
                        width: overlayFrame.width,
                        height: furiganaFont.lineHeight
                    ))
                }
            }
            return true
        }

        overlay.apply(
            overlayFrame: overlayFrame,
            headwordBandRects: headwordRects,
            furiganaLineBandRects: furiganaRects,
            headwordBandsEnabled: debugHeadwordLineBands,
            furiganaLineBandsEnabled: debugFuriganaLineBands
        )
    }

    // Connects the on-screen editor callbacks back to SwiftUI state.
    func makeCoordinator() -> RichTextEditorCoordinator {
        RichTextEditorCoordinator(text: $text, textSize: $textSize, onScrollOffsetYChanged: onScrollOffsetYChanged)
    }

    // Applies font, kerning, and paragraph spacing to both content and typing attributes.
    private func applyTypography(to textView: UITextView, text: String) {
        let font = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        textView.textContainerInset = UIEdgeInsets(
            top: furiganaFont.lineHeight + CGFloat(furiganaGap) + 4,
            left: 4, bottom: 8, right: 4
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing + (font.lineHeight * 0.5)
        paragraphStyle.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: kerning,
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label,
        ]

        // Keeps the hidden editor lightweight because read-mode enhancements render in FuriganaTextRenderer.
        textView.attributedText = NSAttributedString(string: text, attributes: baseAttributes)
        textView.typingAttributes = baseAttributes
    }

    // Captures the editor inputs that require a full attributed-text rebuild when they change.
    private var styleSignature: RichTextEditorStyleSignature {
        RichTextEditorStyleSignature(
            textSize: textSize,
            lineSpacing: lineSpacing,
            kerning: kerning,
            isLineWrappingEnabled: isLineWrappingEnabled,
            isEditMode: isEditMode
        )
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

    // Identifies ranges that should not affect segment color parity (spacing and punctuation only).
    private func shouldIgnoreSegmentForAlternation(_ segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }

    // Checks whether a segment resolves through the segmenter's trie plus deinflection path.
    private func isSegmentInDictionary(_ surface: String) -> Bool {
        segmenter.resolvesSurface(surface)
    }
}
