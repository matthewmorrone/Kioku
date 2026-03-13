import SwiftUI
import UIKit

// Renders the read-mode text surface with furigana overlayed above segments while preserving text-view layout.
struct FuriganaTextRenderer: UIViewRepresentable {
    let isActive: Bool
    let isOverlayFrozen: Bool
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
    let unknownSegmentLocations: Set<Int>
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

        let overlayView = FuriganaOverlayView()
        overlayView.tag = 7_332
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        textView.addSubview(overlayView)

        return textView
    }

    // Syncs text-view typography and positions furigana overlays above segment rects from the same layout engine.
    func updateUIView(_ uiView: UITextView, context: Context) {
        guard let overlayView = uiView.viewWithTag(7_332) as? FuriganaOverlayView else { return }
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

        if isOverlayFrozen {
            return
        }

        let renderSignature = makeRenderSignature(for: textView)
        guard context.coordinator.shouldRender(for: renderSignature) else {
            return
        }

        let baseTextRenderSignature = makeBaseTextRenderSignature(for: textView)

        let textStylePayload = ReadTextStyleResolver(
            text: text,
            segmentationRanges: segmentationRanges,
            textSize: textSize,
            lineSpacing: lineSpacing,
            kerning: kerning,
            isLineWrappingEnabled: isLineWrappingEnabled,
            isVisualEnhancementsEnabled: isVisualEnhancementsEnabled,
            isColorAlternationEnabled: isColorAlternationEnabled,
            isHighlightUnknownEnabled: isHighlightUnknownEnabled,
            unknownSegmentLocations: unknownSegmentLocations
        ).makePayload()
        if context.coordinator.shouldRenderText(for: baseTextRenderSignature) {
            let preservedOffsetY = textView.contentOffset.y
            textView.attributedText = textStylePayload.attributedText
            ensureTextLayout(for: textView)
            let minOffsetY = -textView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            let clampedOffsetY = min(max(preservedOffsetY, minOffsetY), maxOffsetY)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffsetY), animated: false)
            context.coordinator.markTextRendered(signature: baseTextRenderSignature)
        }

        ensureTextLayout(for: textView, exhaustive: true)

        let overlayFrame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(textView.contentSize.width, textView.bounds.width),
                height: max(textView.contentSize.height, textView.bounds.height)
            )
        )

        var selectedSegmentRect: CGRect?
        var selectedSegmentColor: UIColor?
        if let selectedSegmentRange = selectedSegmentNSRange(in: text),
           let selectedRect = segmentRectInTextView(textView: textView, nsRange: selectedSegmentRange) {
            selectedSegmentColor = UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor.systemYellow.withAlphaComponent(0.26)
                    : UIColor.systemYellow.withAlphaComponent(0.32)
            }
            selectedSegmentRect = selectedRect.insetBy(dx: -1, dy: 0)
        }

        var illegalBoundaryRect: CGRect?
        var illegalBoundaryColor: UIColor?
        if let illegalMergeBoundaryLocation,
           let boundaryRect = boundaryIndicatorRectInTextView(
            textView: textView,
            boundaryUTF16Location: illegalMergeBoundaryLocation
           ) {
            illegalBoundaryColor = UIColor.systemRed.withAlphaComponent(0.9)
            illegalBoundaryRect = boundaryRect
        }

        var furiganaStrings: [String] = []
        var furiganaFrames: [CGRect] = []
        var furiganaColors: [UIColor] = []

        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        if isVisualEnhancementsEnabled {
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
                guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else {
                    continue
                }

                let furiganaWidth = max(measureTextWidth(furigana, font: furiganaFont, kerning: 0), segmentRect.width)
                let furiganaX = segmentRect.midX - (furiganaWidth / 2)
                furiganaStrings.append(furigana)
                furiganaFrames.append(
                    CGRect(
                        x: furiganaX,
                        y: max(segmentRect.minY - furiganaFont.lineHeight + 1, 0),
                        width: furiganaWidth,
                        height: furiganaFont.lineHeight
                    )
                )
                furiganaColors.append(textStylePayload.segmentForegroundByLocation[location] ?? .secondaryLabel)
            }
        }

        overlayView.apply(
            overlayFrame: overlayFrame,
            selectedSegmentRect: selectedSegmentRect,
            selectedSegmentColor: selectedSegmentColor,
            illegalBoundaryRect: illegalBoundaryRect,
            illegalBoundaryColor: illegalBoundaryColor,
            furiganaStrings: furiganaStrings,
            furiganaFrames: furiganaFrames,
            furiganaColors: furiganaColors,
            furiganaFont: furiganaFont
        )

        guard isVisualEnhancementsEnabled || selectedSegmentRect != nil || illegalBoundaryRect != nil else {
            context.coordinator.markRendered(signature: renderSignature)
            return
        }

        context.coordinator.markRendered(signature: renderSignature)
    }

    // Resolves the visual segment rectangle used to anchor furigana over the same glyph layout.
    private func segmentRectInTextView(textView: UITextView, nsRange: NSRange) -> CGRect? {
        guard
            nsRange.location != NSNotFound,
            nsRange.length > 0,
            let textRange = textRange(in: textView, nsRange: nsRange)
        else {
            return nil
        }

        ensureTextLayout(for: textView)
        let segmentRect = textView.firstRect(for: textRange)
        guard segmentRect.isNull == false, segmentRect.isInfinite == false, segmentRect.isEmpty == false else {
            return nil
        }

        return segmentRect
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
        guard
            let previousTextRange = textRange(in: textView, nsRange: NSRange(location: boundaryUTF16Location - 1, length: 1)),
            let nextTextRange = textRange(in: textView, nsRange: NSRange(location: boundaryUTF16Location, length: 1))
        else {
            return nil
        }

        let previousRect = textView.firstRect(for: previousTextRange)
        let nextRect = textView.firstRect(for: nextTextRange)
        guard
            previousRect.isNull == false,
            previousRect.isInfinite == false,
            previousRect.isEmpty == false,
            nextRect.isNull == false,
            nextRect.isInfinite == false,
            nextRect.isEmpty == false
        else {
            return nil
        }

        let lineTopY = min(previousRect.minY, nextRect.minY)
        let lineBottomY = max(previousRect.maxY, nextRect.maxY)
        return CGRect(
            x: nextRect.minX - 1.5,
            y: lineTopY - 3,
            width: 3,
            height: max((lineBottomY - lineTopY) + 6, 16)
        )
    }

    // Forces lazy TextKit layout to complete before any geometry is queried for annotations.
    private func ensureTextLayout(for textView: UITextView, exhaustive: Bool = false) {
        if exhaustive,
           let textLayoutManager = textView.textLayoutManager,
           let documentRange = textLayoutManager.textContentManager?.documentRange {
            textLayoutManager.ensureLayout(for: documentRange)
        } else {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        textView.layoutIfNeeded()
    }

    // Converts a UTF-16 range into the UITextInput range used by TextKit 2 geometry queries.
    private func textRange(in textView: UITextView, nsRange: NSRange) -> UITextRange? {
        let documentStart = textView.beginningOfDocument
        guard
            let rangeStart = textView.position(from: documentStart, offset: nsRange.location),
            let rangeEnd = textView.position(from: rangeStart, offset: nsRange.length)
        else {
            return nil
        }

        return textView.textRange(from: rangeStart, to: rangeEnd)
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
        for location in unknownSegmentLocations.sorted() {
            hasher.combine(location)
        }
        hasher.combine(textView.bounds.width)
        hasher.combine(textView.bounds.height)
        hasher.combine(textView.contentSize.width)
        hasher.combine(textView.contentSize.height)
        // Keeps furigana geometry checks in sync with fine-grained scroll movement.
        hasher.combine(Int((externalContentOffsetY * 10).rounded()))
        return hasher.finalize()
    }

    // Builds a stable signature for read-mode base text styling changes.
    private func makeBaseTextRenderSignature(for textView: UITextView) -> Int {
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
        for location in unknownSegmentLocations.sorted() {
            hasher.combine(location)
        }
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

    // Finds the selected segment NSRange so overlay highlighting can target the tapped segment.
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

}
