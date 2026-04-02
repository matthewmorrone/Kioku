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
    let playbackHighlightRangeOverride: NSRange?
    let activePlaybackCueIndex: Int?
    let illegalMergeBoundaryLocation: Int?
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isVisualEnhancementsEnabled: Bool
    let isColorAlternationEnabled: Bool
    let isHighlightUnknownEnabled: Bool
    let unknownSegmentLocations: Set<Int>
    // UTF-16 segment start locations changed by the most recent LLM correction (pending confirmation).
    let changedSegmentLocations: Set<Int>
    // Subset of changedSegmentLocations where only the furigana reading changed (surface unchanged).
    let changedReadingLocations: Set<Int>
    let segmenter: any TextSegmenting
    // Hex strings for user-configured segment alternation colors. Empty string = use system default.
    let customEvenSegmentColorHex: String
    let customOddSegmentColorHex: String
    // Debug overlay flags — all false in production use.
    let debugFuriganaRects: Bool
    let debugHeadwordRects: Bool
    let debugHeadwordLineBands: Bool
    let debugFuriganaLineBands: Bool
    let externalContentOffsetY: CGFloat
    let onScrollOffsetYChanged: (CGFloat) -> Void
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let furiganaGap: Double

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
        context.coordinator.markMakeUIViewIfNeeded()
        let textView = TextViewFactory.makeTextView()
        textView.delegate = context.coordinator
        textView.textLayoutManager?.delegate = context.coordinator
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

        context.coordinator.markFirstActiveUpdateIfNeeded(
            textLength: text.utf16.count,
            segmentCount: segmentationRanges.count,
            furiganaCount: furiganaBySegmentLocation.count
        )

        context.coordinator.onScrollOffsetYChanged = onScrollOffsetYChanged
        context.coordinator.onSegmentTapped = onSegmentTapped
        context.coordinator.configureTapSegmentationRanges(segmentationRanges, in: text)
        configureWrapping(for: textView)
        if context.coordinator.shouldApplyInitialExternalSync(isActive: true) {
            context.coordinator.markStartupPhase("FuriganaTextRenderer applying initial external scroll sync")
            context.coordinator.applyExternalScrollIfNeeded(to: textView, targetOffsetY: externalContentOffsetY)
        }

        if isOverlayFrozen {
            context.coordinator.markStartupPhase("FuriganaTextRenderer overlay frozen")
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
            unknownSegmentLocations: unknownSegmentLocations,
            changedSegmentLocations: changedSegmentLocations,
            changedReadingLocations: changedReadingLocations,
            customEvenSegmentColor: customEvenSegmentColorHex.isEmpty ? nil : UIColor(hexString: customEvenSegmentColorHex),
            customOddSegmentColor: customOddSegmentColorHex.isEmpty ? nil : UIColor(hexString: customOddSegmentColorHex)
        ).makePayload()
        // Top inset must accommodate the furigana row above the first line so it matches
        // the spacing above all other lines (which comes from paragraph lineSpacing).
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        textView.textContainerInset = UIEdgeInsets(
            top: furiganaFont.lineHeight + CGFloat(furiganaGap) + 4,
            left: 4, bottom: 8, right: 4
        )

        if context.coordinator.shouldRenderText(for: baseTextRenderSignature) {
            context.coordinator.markFirstTextRenderIfNeeded()
            // Use the external scroll target instead of the current UITextView offset so that
            // scroll-to-top on note switch (sharedScrollOffsetY = 0) takes effect when text changes.
            // During normal style updates the external offset stays in sync with the actual position.
            textView.attributedText = textStylePayload.attributedText
            // Run the exhaustive full-document layout here, immediately after setting attributedText,
            // so glyph positions used by overlay drawing are correct before the view is displayed.
            // Doing this inside the text-change branch avoids blocking the main thread on every
            // scroll-driven updateUIView call (which would cause gesture-gate timeouts on large notes).
            ensureTextLayout(for: textView, coordinator: context.coordinator, exhaustive: true)
            let minOffsetY = -textView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            let clampedOffsetY = min(max(externalContentOffsetY, minOffsetY), maxOffsetY)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffsetY), animated: false)
            context.coordinator.markTextRendered(signature: baseTextRenderSignature)
        } else {
            // Text is unchanged; the full layout from the last text-change pass is still valid.
            // Run the viewport-only layout so newly-scrolled-into-view fragments are ready for
            // overlay drawing without re-laying out the entire document.
            ensureTextLayout(for: textView, coordinator: context.coordinator)
        }

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

        var playbackHighlightRect: CGRect?
        var playbackHighlightColor: UIColor?
        if let playbackHighlightRange = playbackHighlightNSRange(in: text),
           let playbackRect = segmentRectInTextView(textView: textView, nsRange: playbackHighlightRange) {
            playbackHighlightColor = UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor.systemMint.withAlphaComponent(0.28)
                    : UIColor.systemTeal.withAlphaComponent(0.20)
            }
            playbackHighlightRect = playbackRect.insetBy(dx: -6, dy: -2)
            context.coordinator.applyPlaybackAutoscrollIfNeeded(
                to: textView,
                cueIndex: activePlaybackCueIndex,
                targetRect: playbackRect
            )
        } else {
            context.coordinator.clearPlaybackAutoscrollState()
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

                let furiganaWidth = measureTextWidth(furigana, font: furiganaFont, kerning: 0)
                let furiganaX = segmentRect.midX - (furiganaWidth / 2)
                furiganaStrings.append(furigana)
                furiganaFrames.append(
                    CGRect(
                        x: furiganaX,
                        y: max(segmentRect.minY - furiganaFont.lineHeight - furiganaGap, 0),
                        width: furiganaWidth,
                        height: furiganaFont.lineHeight
                    )
                )
                furiganaColors.append(textStylePayload.segmentForegroundByLocation[location] ?? .secondaryLabel)
            }
        }

        // Collects a rect for every non-whitespace segment for the headword debug overlay.
        // Uses the full segment range so okurigana is included alongside the kanji run.
        var debugCollectedHeadwordRects: [CGRect] = []
        var debugCollectedHeadwordColors: [UIColor] = []
        if debugHeadwordRects {
            let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            for segmentRange in segmentationRanges {
                let segmentText = String(text[segmentRange])
                guard !segmentText.unicodeScalars.allSatisfy({ ignoredScalars.contains($0) }) else { continue }
                let nsRange = NSRange(segmentRange, in: text)
                guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
                guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else { continue }
                debugCollectedHeadwordRects.append(segmentRect)
                debugCollectedHeadwordColors.append(
                    textStylePayload.segmentForegroundByLocation[nsRange.location] ?? .label
                )
            }
        }

        // Collects per-line rects for headword and furigana band debug overlays.
        // Uses firstRect(for:) — the same coordinate pipeline as furigana frame computation — so
        // the bands land in exactly the same space as all other overlay geometry.
        var debugHeadwordLineBandRects: [CGRect] = []
        var debugFuriganaLineBandRects: [CGRect] = []
        let needsLineBands = debugHeadwordLineBands || debugFuriganaLineBands
        if needsLineBands,
           let tlm = textView.textLayoutManager,
           let tcm = tlm.textContentManager {
            let docStart = tcm.documentRange.location
            let bodyFont = UIFont.systemFont(ofSize: textSize)
            // Use the font's own lineHeight for band height so every line — including blank
            // ones — is measured consistently. caretRect.height is unreliable on blank lines
            // because UIKit falls back to an internal default rather than reading the attributed font.
            let bandHeight = bodyFont.lineHeight
            tlm.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
                // Convert the fragment's start to an integer UTF-16 offset in the document.
                let fragmentOffset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
                for lineFragment in fragment.textLineFragments {
                    let lineCharRange = lineFragment.characterRange
                    let lineDocStart = fragmentOffset + lineCharRange.location
                    guard let anchorPosition = textView.position(
                        from: textView.beginningOfDocument,
                        offset: lineDocStart
                    ) else { continue }
                    // caretRect is used only for the y position; height comes from font metrics.
                    let caretR = textView.caretRect(for: anchorPosition)
                    guard caretR.isNull == false,
                          caretR.isInfinite == false,
                          caretR.height > 0 else { continue }
                    // Blank lines have no furigana, so their headword band is shifted up by
                    // furiganaRowHeight to eliminate the empty furigana slot above them. This
                    // produces 0 space above and 2× furiganaRowHeight below — matching the
                    // user's description of the desired blank-line band layout.
                    let textNS = textView.text as NSString
                    let isBlankLine = lineDocStart < textNS.length
                        ? textNS.character(at: lineDocStart) == 0x000A
                        : true
                    if debugHeadwordLineBands {
                        let bandY = isBlankLine ? caretR.minY + furiganaFont.lineHeight + CGFloat(lineSpacing) : caretR.minY
                        debugHeadwordLineBandRects.append(CGRect(
                            x: 0,
                            y: bandY,
                            width: overlayFrame.width,
                            height: bandHeight
                        ))
                    }
                    if debugFuriganaLineBands && !isBlankLine {
                        debugFuriganaLineBandRects.append(CGRect(
                            x: 0,
                            y: caretR.minY - furiganaFont.lineHeight - CGFloat(furiganaGap),
                            width: overlayFrame.width,
                            height: furiganaFont.lineHeight
                        ))
                    }
                }
                return true
            }
        }

        overlayView.apply(
            overlayFrame: overlayFrame,
            selectedSegmentRect: selectedSegmentRect,
            selectedSegmentColor: selectedSegmentColor,
            playbackHighlightRect: playbackHighlightRect,
            playbackHighlightColor: playbackHighlightColor,
            illegalBoundaryRect: illegalBoundaryRect,
            illegalBoundaryColor: illegalBoundaryColor,
            furiganaStrings: furiganaStrings,
            furiganaFrames: furiganaFrames,
            furiganaColors: furiganaColors,
            furiganaFont: furiganaFont,
            debugFuriganaRectsEnabled: debugFuriganaRects,
            debugHeadwordRectsEnabled: debugHeadwordRects,
            debugHeadwordLineBandsEnabled: debugHeadwordLineBands,
            debugFuriganaLineBandsEnabled: debugFuriganaLineBands,
            debugHeadwordRects: debugCollectedHeadwordRects,
            debugHeadwordColors: debugCollectedHeadwordColors,
            debugHeadwordLineBandRects: debugHeadwordLineBandRects,
            debugFuriganaLineBandRects: debugFuriganaLineBandRects
        )
        context.coordinator.markFirstOverlayApplyIfNeeded(furiganaCount: furiganaStrings.count)

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

        ensureTextLayout(for: textView, coordinator: nil)
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

        ensureTextLayout(for: textView, coordinator: nil)
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
    private func ensureTextLayout(for textView: UITextView, coordinator: FuriganaTextRendererCoordinator?, exhaustive: Bool = false) {
        coordinator?.markFirstLayoutIfNeeded(exhaustive: exhaustive)
        if exhaustive {
            StartupTimer.measure("FuriganaTextRenderer.ensureTextLayout.exhaustive") {
                guard let textLayoutManager = textView.textLayoutManager,
                      let documentRange = textLayoutManager.textContentManager?.documentRange else {
                    return
                }
                textLayoutManager.ensureLayout(for: documentRange)
                // TextKit 2 does not synchronously update UITextView.contentSize after ensureLayout,
                // so user scroll physics are capped at the lazily-computed partial height. Fix by
                // reading the last layout fragment's maxY and patching contentSize when it is too small.
                var maxLayoutY: CGFloat = 0
                textLayoutManager.enumerateTextLayoutFragments(from: documentRange.endLocation, options: [.reverse]) { fragment in
                    maxLayoutY = fragment.layoutFragmentFrame.maxY
                    return false
                }
                let requiredHeight = textView.textContainerInset.top + maxLayoutY + textView.textContainerInset.bottom
                if requiredHeight > textView.contentSize.height {
                    textView.contentSize = CGSize(width: textView.contentSize.width, height: requiredHeight)
                }
            }
        } else {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        if exhaustive {
            StartupTimer.mark("FuriganaTextRenderer exhaustive layout finished")
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
        hasher.combine(playbackHighlightRangeOverride?.location)
        hasher.combine(playbackHighlightRangeOverride?.length)
        hasher.combine(activePlaybackCueIndex)
        hasher.combine(illegalMergeBoundaryLocation)
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(furiganaGap)
        hasher.combine(isActive)
        hasher.combine(isColorAlternationEnabled)
        hasher.combine(isHighlightUnknownEnabled)
        for location in unknownSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedReadingLocations.sorted() {
            hasher.combine(location)
        }
        hasher.combine(textView.bounds.width)
        hasher.combine(textView.bounds.height)
        hasher.combine(textView.contentSize.width)
        hasher.combine(textView.contentSize.height)
        // Keeps furigana geometry checks in sync with fine-grained scroll movement.
        hasher.combine(Int((externalContentOffsetY * 10).rounded()))
        // Debug flag changes must invalidate the overlay so toggling takes effect immediately.
        hasher.combine(debugFuriganaRects)
        hasher.combine(debugHeadwordRects)
        hasher.combine(debugHeadwordLineBands)
        hasher.combine(debugFuriganaLineBands)
        hasher.combine(customEvenSegmentColorHex)
        hasher.combine(customOddSegmentColorHex)
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
        for location in changedSegmentLocations.sorted() {
            hasher.combine(location)
        }
        for location in changedReadingLocations.sorted() {
            hasher.combine(location)
        }
        hasher.combine(textSize)
        hasher.combine(lineSpacing)
        hasher.combine(kerning)
        hasher.combine(furiganaGap)
        hasher.combine(isActive)
        // Custom token color changes affect ReadTextStyleResolver output; include them in the text signature.
        hasher.combine(customEvenSegmentColorHex)
        hasher.combine(customOddSegmentColorHex)
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

    private func playbackHighlightNSRange(in sourceText: String) -> NSRange? {
        guard let playbackHighlightRangeOverride,
              playbackHighlightRangeOverride.location != NSNotFound,
              playbackHighlightRangeOverride.length > 0,
              playbackHighlightRangeOverride.upperBound <= (sourceText as NSString).length else {
            return nil
        }

        return playbackHighlightRangeOverride
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
