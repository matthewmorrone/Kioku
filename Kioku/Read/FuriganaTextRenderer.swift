import SwiftUI
import UIKit

// Renders the read-mode text surface with furigana overlayed above tokens while preserving text-view layout.
struct FuriganaTextRenderer: UIViewRepresentable {
    let isActive: Bool
    let text: String
    let isLineWrappingEnabled: Bool
    let segmentationRanges: [Range<String.Index>]
    let selectedSegmentLocation: Int?
    let selectedHighlightRangeOverride: NSRange?
    let illegalMergeBoundaryLocation: Int?
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isVisualEnhancementsEnabled: Bool
    let isColorAlternationEnabled: Bool
    let isHighlightUnknownEnabled: Bool
    let segmenter: Segmenter
    let externalContentOffsetY: CGFloat
    let onScrollOffsetYChanged: (CGFloat) -> Void
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double

    // Creates coordinator state used to skip redundant expensive furigana layout passes.
    func makeCoordinator() -> FuriganaTextRendererCoordinator {
        FuriganaTextRendererCoordinator(
            textSize: $textSize,
            onScrollOffsetYChanged: onScrollOffsetYChanged,
            onSegmentTapped: onSegmentTapped
        )
    }

    // Builds the read-mode text view with a furigana overlay that scrolls with text content.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.layoutManager.delegate = context.coordinator
        textView.tag = 7_331
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        configureWrapping(for: textView)
        textView.clipsToBounds = true
        let pinchRecognizer = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(FuriganaTextRendererCoordinator.handlePinch(_:)))
        pinchRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(pinchRecognizer)
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(FuriganaTextRendererCoordinator.handleTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(tapRecognizer)

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

        guard isActive else {
            context.coordinator.updateActiveState(isActive: false)
            return
        }

        context.coordinator.onScrollOffsetYChanged = onScrollOffsetYChanged
        context.coordinator.onSegmentTapped = onSegmentTapped
        context.coordinator.configureTapSegmentationRanges(segmentationRanges, in: text)
        configureWrapping(for: textView)
        if context.coordinator.shouldApplyInitialExternalSync(isActive: true) {
            context.coordinator.applyExternalScrollIfNeeded(to: textView, targetOffsetY: externalContentOffsetY)
        }

        ensureTextLayout(for: textView)

        let renderSignature = makeRenderSignature(for: textView)
        guard context.coordinator.shouldRender(for: renderSignature) else {
            return
        }

        let textRenderSignature = makeTextRenderSignature(for: textView)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlayView.subviews.forEach { $0.removeFromSuperview() }

        let renderPayload = makeAttributedBaseText()
        if context.coordinator.shouldRenderText(for: textRenderSignature) {
            let preservedOffsetY = textView.contentOffset.y
            textView.attributedText = renderPayload.attributedText
            ensureTextLayout(for: textView)
            let minOffsetY = -textView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            let clampedOffsetY = min(max(preservedOffsetY, minOffsetY), maxOffsetY)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffsetY), animated: false)
            context.coordinator.markTextRendered(signature: textRenderSignature)
        }

        overlayView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(textView.contentSize.width, textView.bounds.width),
                height: max(textView.contentSize.height, textView.bounds.height)
            )
        )

        if let selectedSegmentRange = selectedSegmentNSRange(in: text),
           let selectedSegmentRect = tokenRectInTextView(textView: textView, nsRange: selectedSegmentRange) {
            let selectedSegmentBackground = UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor.systemYellow.withAlphaComponent(0.26)
                    : UIColor.systemYellow.withAlphaComponent(0.32)
            }

            let highlightView = UIView(frame: selectedSegmentRect.insetBy(dx: -1, dy: 0))
            highlightView.backgroundColor = selectedSegmentBackground
            highlightView.layer.cornerRadius = 4
            highlightView.isUserInteractionEnabled = false
            overlayView.addSubview(highlightView)
        }

        if let illegalMergeBoundaryLocation,
           let illegalBoundaryRect = boundaryIndicatorRectInTextView(
            textView: textView,
            boundaryUTF16Location: illegalMergeBoundaryLocation
           ) {
            let boundaryView = UIView(frame: illegalBoundaryRect)
            boundaryView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.9)
            boundaryView.layer.cornerRadius = 1.5
            boundaryView.isUserInteractionEnabled = false
            overlayView.addSubview(boundaryView)
        }

        guard isVisualEnhancementsEnabled else {
            context.coordinator.markRendered(signature: renderSignature)
            return
        }

        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        for location in furiganaBySegmentLocation.keys.sorted() {
            guard
                let furigana = furiganaBySegmentLocation[location],
                !furigana.isEmpty,
                let length = furiganaLengthBySegmentLocation[location],
                length > 0
            else {
                continue
            }

            let nsRange = NSRange(location: location, length: length)
            guard let tokenRect = tokenRectInTextView(textView: textView, nsRange: nsRange) else {
                continue
            }

            let furiganaWidth = max(measureTextWidth(furigana, font: furiganaFont, kerning: 0), tokenRect.width)
            let furiganaX = tokenRect.midX - (furiganaWidth / 2)

            let furiganaLabel = UILabel()
            furiganaLabel.backgroundColor = .clear
            furiganaLabel.font = furiganaFont
            furiganaLabel.textColor = renderPayload.tokenColorByLocation[location] ?? .secondaryLabel
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

        CATransaction.commit()

        context.coordinator.markRendered(signature: renderSignature)
    }

    // Creates the base attributed text so view-mode wrapping and spacing match the edit-mode text view.
    private func makeAttributedBaseText() -> (attributedText: NSAttributedString, tokenColorByLocation: [Int: UIColor]) {
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing + (baseFont.lineHeight * 0.5)
        paragraphStyle.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping

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
        let unknownSegmentForeground = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemYellow : .systemOrange
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

            // Highlights unknown tokens only when alternation is active; otherwise keep default foreground styling.
            if isHighlightUnknownEnabled && isColorAlternationEnabled && !isTokenInDictionary(segmentText) {
                attributedText.addAttribute(.foregroundColor, value: unknownSegmentForeground, range: nsRange)
                for offset in 0..<nsRange.length {
                    tokenColorByLocation[nsRange.location + offset] = unknownSegmentForeground
                }
            } else if isColorAlternationEnabled {
                // Alternates foreground colors by segment index so token boundaries remain visually distinct.
                if colorAlternationIndex.isMultiple(of: 2) {
                    attributedText.addAttribute(.foregroundColor, value: evenSegmentForeground, range: nsRange)
                    for offset in 0..<nsRange.length {
                        tokenColorByLocation[nsRange.location + offset] = evenSegmentForeground
                    }
                } else {
                    attributedText.addAttribute(.foregroundColor, value: oddSegmentForeground, range: nsRange)
                    for offset in 0..<nsRange.length {
                        tokenColorByLocation[nsRange.location + offset] = oddSegmentForeground
                    }
                }
            }

            colorAlternationIndex += 1
        }

        return (attributedText: attributedText, tokenColorByLocation: tokenColorByLocation)
    }

    // Resolves the visual token rectangle used to anchor furigana over the same glyph layout.
    private func tokenRectInTextView(textView: UITextView, nsRange: NSRange) -> CGRect? {
        guard nsRange.location != NSNotFound, nsRange.length > 0 else {
            return nil
        }

        ensureTextLayout(for: textView)
        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            return nil
        }

        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
        guard glyphRect.isNull == false, glyphRect.isInfinite == false, glyphRect.isEmpty == false else {
            return nil
        }

        return textViewRect(for: glyphRect, in: textView)
    }

    // Keeps the text container in wrapped or horizontal-scroll layout based on the display option.
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

    // Resolves a thin rect at a UTF-16 boundary for illegal-merge flash feedback.
    private func boundaryIndicatorRectInTextView(textView: UITextView, boundaryUTF16Location: Int) -> CGRect? {
        let textLength = (textView.text as NSString).length
        guard boundaryUTF16Location > 0, boundaryUTF16Location < textLength else {
            return nil
        }

        ensureTextLayout(for: textView)
        let layoutManager = textView.layoutManager
        let nextCharacterRange = NSRange(location: boundaryUTF16Location, length: 1)
        let nextGlyphRange = layoutManager.glyphRange(forCharacterRange: nextCharacterRange, actualCharacterRange: nil)
        guard nextGlyphRange.length > 0 else {
            return nil
        }

        let nextGlyphRect = layoutManager.boundingRect(forGlyphRange: nextGlyphRange, in: textView.textContainer)
        let lineFragmentRect = layoutManager.lineFragmentUsedRect(forGlyphAt: nextGlyphRange.location, effectiveRange: nil)
        guard
            nextGlyphRect.isNull == false,
            nextGlyphRect.isInfinite == false,
            lineFragmentRect.isNull == false,
            lineFragmentRect.isInfinite == false
        else {
            return nil
        }

        let textViewLineRect = textViewRect(for: lineFragmentRect, in: textView)
        let textViewNextGlyphRect = textViewRect(for: nextGlyphRect, in: textView)
        let indicatorHeight = max(textViewLineRect.height + 6, 16)
        return CGRect(
            x: textViewNextGlyphRect.minX - 1.5,
            y: textViewLineRect.minY - 3,
            width: 3,
            height: indicatorHeight
        )
    }

    // Converts a TextKit text-container rect into text-view coordinates for overlay placement.
    private func textViewRect(for rect: CGRect, in textView: UITextView) -> CGRect {
        CGRect(
            x: rect.origin.x + textView.textContainerInset.left,
            y: rect.origin.y + textView.textContainerInset.top,
            width: rect.width,
            height: rect.height
        )
    }

    // Forces lazy TextKit layout to complete before any geometry is queried for annotations.
    private func ensureTextLayout(for textView: UITextView) {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
    }

    // Builds a stable signature so expensive rendering only runs when visual inputs actually change.
    private func makeRenderSignature(for textView: UITextView) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            hasher.combine(nsRange.location)
            hasher.combine(nsRange.length)
        }
        hasher.combine(isLineWrappingEnabled)
        let furiganaLocations = furiganaBySegmentLocation.keys.sorted()
        for location in furiganaLocations {
            hasher.combine(location)
            hasher.combine(furiganaBySegmentLocation[location])
            hasher.combine(furiganaLengthBySegmentLocation[location] ?? 0)
        }
        hasher.combine(selectedSegmentLocation)
        hasher.combine(selectedHighlightRangeOverride?.location)
        hasher.combine(selectedHighlightRangeOverride?.length)
        hasher.combine(illegalMergeBoundaryLocation)
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(isActive)
        hasher.combine(isColorAlternationEnabled)
        hasher.combine(isHighlightUnknownEnabled)
        hasher.combine(textView.bounds.width)
        hasher.combine(textView.bounds.height)
        hasher.combine(textView.contentSize.width)
        hasher.combine(textView.contentSize.height)
        return hasher.finalize()
    }

    // Builds a stable signature for base text styling changes that require replacing attributed text.
    private func makeTextRenderSignature(for textView: UITextView) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            hasher.combine(nsRange.location)
            hasher.combine(nsRange.length)
        }
        hasher.combine(isLineWrappingEnabled)
        hasher.combine(isVisualEnhancementsEnabled)
        hasher.combine(isColorAlternationEnabled)
        hasher.combine(isHighlightUnknownEnabled)
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(isActive)
        hasher.combine(textView.bounds.width)
        hasher.combine(textView.bounds.height)
        hasher.combine(textView.contentSize.width)
        hasher.combine(textView.contentSize.height)
        return hasher.finalize()
    }

    // Finds the selected segment NSRange so overlay highlighting can target the tapped token.
    private func selectedSegmentNSRange(in sourceText: String) -> NSRange? {
        if let selectedHighlightRangeOverride,
           selectedHighlightRangeOverride.location != NSNotFound,
           selectedHighlightRangeOverride.length > 0,
           selectedHighlightRangeOverride.upperBound <= (sourceText as NSString).length {
            return selectedHighlightRangeOverride
        }

        guard let selectedSegmentLocation else {
            return nil
        }

        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: sourceText)
            if nsRange.location == selectedSegmentLocation, nsRange.length > 0 {
                return nsRange
            }
        }

        return nil
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

    // Checks whether a token resolves through the segmenter's trie plus deinflection path.
    private func isTokenInDictionary(_ surface: String) -> Bool {
        segmenter.resolvesSurface(surface)
    }
}
