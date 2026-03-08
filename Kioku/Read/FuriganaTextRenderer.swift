import SwiftUI
import UIKit

// Renders the read-mode text surface with furigana overlayed above tokens while preserving text-view layout.
struct FuriganaTextRenderer: UIViewRepresentable {
    let text: String
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let isVisualEnhancementsEnabled: Bool
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double

    // Creates coordinator state used to skip redundant expensive furigana layout passes.
    func makeCoordinator() -> FuriganaTextRendererCoordinator {
        FuriganaTextRendererCoordinator(textSize: $textSize)
    }

    // Builds the read-mode text view with a furigana overlay that scrolls with text content.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.tag = 7_331
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.clipsToBounds = true
        let pinchRecognizer = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(FuriganaTextRendererCoordinator.handlePinch(_:)))
        pinchRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(pinchRecognizer)

        let overlayView = UIView()
        overlayView.tag = 7_332
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        textView.addSubview(overlayView)

        return textView
    }

    // Syncs text-view typography and positions furigana overlays above token rects from the same layout engine.
    func updateUIView(_ uiView: UITextView, context: Context) {
        guard let overlayView = uiView.viewWithTag(7_332) else { return }
        let textView = uiView

        let renderSignature = makeRenderSignature(for: textView)
        guard context.coordinator.shouldRender(for: renderSignature) else {
            return
        }

        overlayView.subviews.forEach { $0.removeFromSuperview() }

        let renderPayload = makeAttributedBaseText()
        textView.attributedText = renderPayload.attributedText
        textView.layoutIfNeeded()
        overlayView.frame = CGRect(origin: .zero, size: textView.contentSize)

        guard isVisualEnhancementsEnabled else {
            context.coordinator.markRendered(signature: renderSignature)
            return
        }

        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                continue
            }

            guard let furigana = furiganaBySegmentLocation[nsRange.location], !furigana.isEmpty else {
                continue
            }

            guard let tokenRect = tokenRectInTextView(textView: textView, nsRange: nsRange) else {
                continue
            }

            let furiganaWidth = max(measureTextWidth(furigana, font: furiganaFont, kerning: 0), tokenRect.width)
            let furiganaX = tokenRect.midX - (furiganaWidth / 2)

            let furiganaLabel = UILabel()
            furiganaLabel.backgroundColor = .clear
            furiganaLabel.font = furiganaFont
            furiganaLabel.textColor = renderPayload.tokenColorByLocation[nsRange.location] ?? .secondaryLabel
            furiganaLabel.textAlignment = .center
            furiganaLabel.lineBreakMode = .byClipping
            furiganaLabel.text = furigana
            furiganaLabel.frame = CGRect(
                x: furiganaX,
                y: max(tokenRect.minY - furiganaFont.lineHeight + 1, 0),
                width: furiganaWidth,
                height: furiganaFont.lineHeight
            )
            overlayView.addSubview(furiganaLabel)
        }

        context.coordinator.markRendered(signature: renderSignature)
    }

    // Creates the base attributed text so view-mode wrapping and spacing match the edit-mode text view.
    private func makeAttributedBaseText() -> (attributedText: NSAttributedString, tokenColorByLocation: [Int: UIColor]) {
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing + (baseFont.lineHeight * 0.5)
        paragraphStyle.lineBreakMode = .byWordWrapping

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
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

        guard isVisualEnhancementsEnabled else {
            return (attributedText: attributedText, tokenColorByLocation: [:])
        }

        var colorAlternationIndex = 0
        var tokenColorByLocation: [Int: UIColor] = [:]
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                continue
            }

            let segmentText = String(text[segmentRange])
            if shouldIgnoreSegmentForAlternation(segmentText) {
                continue
            }

            if colorAlternationIndex.isMultiple(of: 2) {
                attributedText.addAttribute(.foregroundColor, value: evenSegmentForeground, range: nsRange)
                tokenColorByLocation[nsRange.location] = evenSegmentForeground
            } else {
                attributedText.addAttribute(.foregroundColor, value: oddSegmentForeground, range: nsRange)
                tokenColorByLocation[nsRange.location] = oddSegmentForeground
            }

            colorAlternationIndex += 1
        }

        return (attributedText: attributedText, tokenColorByLocation: tokenColorByLocation)
    }

    // Resolves the visual token rectangle used to anchor furigana over the same glyph layout.
    private func tokenRectInTextView(textView: UITextView, nsRange: NSRange) -> CGRect? {
        let documentStart = textView.beginningOfDocument
        guard
            let rangeStart = textView.position(from: documentStart, offset: nsRange.location),
            let rangeEnd = textView.position(from: rangeStart, offset: nsRange.length),
            let textRange = textView.textRange(from: rangeStart, to: rangeEnd)
        else {
            return nil
        }

        let tokenRect = textView.firstRect(for: textRange)
        if tokenRect.isEmpty {
            return nil
        }

        return tokenRect
    }

    // Builds a stable signature so expensive rendering only runs when visual inputs actually change.
    private func makeRenderSignature(for textView: UITextView) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(segmentationRanges.count)
        hasher.combine(furiganaBySegmentLocation.count)
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(textView.bounds.width)
        hasher.combine(textView.bounds.height)
        return hasher.finalize()
    }

    // Measures text width for furigana label sizing so readings don't collapse into truncation glyphs.
    private func measureTextWidth(_ value: String, font: UIFont, kerning: Double) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: kerning,
        ]
        return ceil((value as NSString).size(withAttributes: attributes).width)
    }

    // Identifies ranges that should not affect token color parity (spacing and punctuation only).
    private func shouldIgnoreSegmentForAlternation(_ segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }
}
