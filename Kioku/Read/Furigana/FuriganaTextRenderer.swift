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
    let blankSelectedSegmentLocation: Int?
    let selectedHighlightRangeOverride: NSRange?
    let playbackHighlightRangeOverride: NSRange?
    let activePlaybackCueIndex: Int?
    let illegalMergeBoundaryLocation: Int?
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isVisualEnhancementsEnabled: Bool
    // User-controlled gate for all ruby-spacing adjustments — pre-layout envelope padding,
    // post-layout kern, and line-start exclusions. Kept independent of visual enhancements so
    // toggling spacing does not drop color alternation, highlighting, etc.
    let isRubySpacingEnabled: Bool
    let isColorAlternationEnabled: Bool
    let isHighlightUnknownEnabled: Bool
    let unknownSegmentLocations: Set<Int>
    // UTF-16 segment start locations changed by the most recent LLM correction (pending confirmation).
    let changedSegmentLocations: Set<Int>
    // Subset of changedSegmentLocations where only the furigana reading changed (surface unchanged).
    let changedReadingLocations: Set<Int>
    // Hex strings for user-configured segment alternation colors. Empty string = use system default.
    let customEvenSegmentColorHex: String
    let customOddSegmentColorHex: String
    // Debug overlay flags — all false in production use.
    let debugFuriganaRects: Bool
    let debugHeadwordRects: Bool
    let debugHeadwordLineBands: Bool
    let debugFuriganaLineBands: Bool
    let debugBisectors: Bool
    let debugEnvelopeRects: Bool
    // Draws a vertical reference line at textContainerInset.left and dumps numerical
    // positions for each line-start segment, so wide-ruby overhang and envelope
    // alignment can be diagnosed without relying on visual eyeballing of the
    // dashed envelope rects.
    let debugLeftInsetGuide: Bool
    let externalContentOffsetY: CGFloat
    let onScrollOffsetYChanged: (CGFloat) -> Void
    let onSegmentTapped: (Int?, CGRect?, UITextView?) -> Void
    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let furiganaGap: Double
    var textAlignment: NSTextAlignment = .natural
    var isScrollEnabled: Bool = true

    // Reports a fixed single-line height when scroll is disabled (e.g. lyrics cue row) so SwiftUI
    // allocates a real frame before the first render. When scrolling is enabled the view fills
    // whatever space SwiftUI offers, so we defer to the default behaviour by returning nil.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard !uiView.isScrollEnabled else { return nil }
        let width = proposal.width ?? uiView.bounds.width
        let bodyFont = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        // Compute actual content height from attributed text bounds when multi-line.
        let insets = uiView.textContainerInset
        let textWidth = max(width - insets.left - insets.right, 0)
        if let attrText = uiView.attributedText, attrText.length > 0 {
            let boundingRect = attrText.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let topInset = furiganaFont.lineHeight + CGFloat(furiganaGap) + 4
            return CGSize(width: width, height: ceil(boundingRect.height) + topInset + 8)
        }
        // Fallback for empty text: single line height.
        let height = furiganaFont.lineHeight + CGFloat(furiganaGap) + 4 + bodyFont.lineHeight + 8
        return CGSize(width: width, height: height)
    }

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
        let textView = TextViewFactory.makeFuriganaRendererTextView()
        textView.delegate = context.coordinator
        // Replay the latest render pipeline once SwiftUI's first layout pass resolves bounds.width,
        // because firstRect returns empty rects at width=0 so the initial updateUIView produces no
        // furigana frames. Without this hook the overlay stays empty until an unrelated state change
        // (e.g. adjusting a slider) happens to trigger another SwiftUI update pass.
        textView.onFirstLayoutResolved = { [weak textView] in
            guard let textView = textView else { return }
            context.coordinator.pendingRender?(textView)
        }
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
        textView.textAlignment = textAlignment
        textView.isScrollEnabled = isScrollEnabled
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
        // Capture the current input snapshot so the custom text view can replay the render pipeline
        // after SwiftUI's first layout pass resolves bounds. Without this, the initial updateUIView
        // call runs at width=0 and produces no furigana frames. The coordinator owns pendingRender,
        // so capture coordinator weakly to avoid a retain cycle through the stored closure.
        let captured = self
        let coordinator = context.coordinator
        coordinator.pendingRender = { [weak coordinator] textView in
            guard let coordinator = coordinator else { return }
            captured.applyRenderState(on: textView, coordinator: coordinator)
        }
        applyRenderState(on: uiView, coordinator: coordinator)
    }

    // Runs the render pipeline: syncs text-view typography and positions furigana overlays above
    // segment rects from the same layout engine. Invoked directly from updateUIView and replayed
    // by the custom text view once SwiftUI resolves the initial bounds.
    private func applyRenderState(on uiView: UITextView, coordinator: FuriganaTextRendererCoordinator) {
        guard let overlayView = uiView.viewWithTag(7_332) as? FuriganaOverlayView else { return }
        let textView = uiView

        guard isActive else {
            coordinator.updateActiveState(isActive: false)
            return
        }

        coordinator.markFirstActiveUpdateIfNeeded(
            textLength: text.utf16.count,
            segmentCount: segmentationRanges.count,
            furiganaCount: furiganaBySegmentLocation.count
        )

        coordinator.onScrollOffsetYChanged = onScrollOffsetYChanged
        coordinator.onSegmentTapped = onSegmentTapped
        coordinator.configureTapSegmentationRanges(segmentationRanges, in: text)
        configureWrapping(for: textView)
        if coordinator.shouldApplyInitialExternalSync(isActive: true) {
            coordinator.markStartupPhase("FuriganaTextRenderer applying initial external scroll sync")
            coordinator.applyExternalScrollIfNeeded(to: textView, targetOffsetY: externalContentOffsetY)
        }

        if isOverlayFrozen {
            coordinator.markStartupPhase("FuriganaTextRenderer overlay frozen")
            return
        }

        let renderSignature = makeRenderSignature(for: textView)
        guard coordinator.shouldRender(for: renderSignature, boundsWidth: textView.bounds.width) else {
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
            customOddSegmentColor: customOddSegmentColorHex.isEmpty ? nil : UIColor(hexString: customOddSegmentColorHex),
            furiganaBySegmentLocation: furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
            textAlignment: textAlignment
        ).makePayload()
        // Top inset must accommodate the furigana row above the first line so it matches
        // the spacing above all other lines (which comes from paragraph lineSpacing).
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        textView.textContainerInset = UIEdgeInsets(
            top: furiganaFont.lineHeight + CGFloat(furiganaGap) + 4,
            left: 4, bottom: 8, right: 4
        )

        let didRenderText = coordinator.shouldRenderText(for: baseTextRenderSignature)
        if didRenderText {
            coordinator.markFirstTextRenderIfNeeded()
            // Clear stale exclusion paths before applying new attributed text. Without this,
            // the existing exclusions shift line-start glyphs right during the fresh layout pass
            // so applyLeftInsetExclusionsForWideRuby's `<= lineStartTolerance` check fails on
            // the already-shifted segments, which then clears the exclusions and snaps glyphs
            // back to x=0 — causing visible alignment jitter on every text-change render.
            textView.textContainer.exclusionPaths = []
            // Use the external scroll target instead of the current UITextView offset so that
            // scroll-to-top on note switch (sharedScrollOffsetY = 0) takes effect when text changes.
            // During normal style updates the external offset stays in sync with the actual position.
            textView.attributedText = textStylePayload.attributedText
            // Run the exhaustive full-document layout here, immediately after setting attributedText,
            // so glyph positions used by overlay drawing are correct before the view is displayed.
            // Doing this inside the text-change branch avoids blocking the main thread on every
            // scroll-driven updateUIView call (which would cause gesture-gate timeouts on large notes).
            ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)
            // Line-start inset pass: adds exclusion paths for any line whose first segment's
            // ruby overhangs left. Called unconditionally — when isRubySpacingEnabled is false
            // the helper itself skips work and clears any lingering exclusions, so flipping
            // the toggle off removes prior spacing corrections instead of leaving them stuck.
            if applyLeftInsetExclusionsForWideRuby(to: textView, furiganaFont: furiganaFont) {
                ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)
            }
            let minOffsetY = -textView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            let clampedOffsetY = min(max(externalContentOffsetY, minOffsetY), maxOffsetY)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffsetY), animated: false)
            coordinator.markTextRendered(signature: baseTextRenderSignature)
        } else {
            // Text is unchanged; a viewport-only pass is enough when the view scrolls, but a
            // non-scrolling preview sizes itself to fit all content, so exhaustive layout keeps
            // the last wrapped line's fragments ready for firstRect queries. Otherwise the last
            // line's furigana can drop out whenever this branch runs without a prior exhaustive
            // pass (e.g. on debug-flag-only changes in Settings).
            ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: !textView.isScrollEnabled)
        }

        let overlayFrame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(textView.contentSize.width, textView.bounds.width),
                height: max(textView.contentSize.height, textView.bounds.height)
            )
        )

        let selectedSegmentRange = selectedSegmentNSRange(in: text)
        var selectedSegmentRect: CGRect?
        var selectedSegmentColor: UIColor?
        if let selectedSegmentRange,
           let selectedRect = segmentRectInTextView(textView: textView, nsRange: selectedSegmentRange),
           let selectedSurfaceRange = Range(selectedSegmentRange, in: text) {
            selectedSegmentColor = UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor.systemYellow.withAlphaComponent(0.26)
                    : UIColor.systemYellow.withAlphaComponent(0.32)
            }
            // Highlight width must cover the segment envelope (max of headword and ruby widths)
            // so a wider ruby like ちから over 力 isn't clipped on the right. Centering matches
            // FuriganaAttributedString's ruby placement: ruby is centered on the headword's
            // visual midpoint.
            let baseFont = UIFont.systemFont(ofSize: textSize)
            let surfaceString = String(text[selectedSurfaceRange])
            let visualHeadwordWidth = measureTextWidth(surfaceString, font: baseFont, kerning: 0)
            var envelopeMinX = selectedRect.minX
            var envelopeMaxX = selectedRect.minX + visualHeadwordWidth
            if let furigana = furiganaBySegmentLocation[selectedSegmentRange.location],
               !furigana.isEmpty,
               let length = furiganaLengthBySegmentLocation[selectedSegmentRange.location], length > 0,
               let surfaceRange = Range(NSRange(location: selectedSegmentRange.location, length: length), in: text),
               let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                   surface: String(text[surfaceRange]), reading: furigana
               ) {
                let furiganaWidth = measureTextWidth(displayReading, font: UIFont.systemFont(ofSize: textSize * 0.5), kerning: 0)
                let headwordWidthForRuby = measureTextWidth(String(text[surfaceRange]), font: baseFont, kerning: 0)
                let kanjiVisualMidX = selectedRect.minX + headwordWidthForRuby / 2
                envelopeMinX = min(envelopeMinX, kanjiVisualMidX - furiganaWidth / 2)
                envelopeMaxX = max(envelopeMaxX, kanjiVisualMidX + furiganaWidth / 2)
            }
            let furiganaRowHeight = furiganaFont.lineHeight + CGFloat(furiganaGap)
            selectedSegmentRect = CGRect(
                x: envelopeMinX - 1,
                y: selectedRect.minY - furiganaRowHeight,
                width: (envelopeMaxX - envelopeMinX) + 2,
                height: selectedRect.height + furiganaRowHeight
            )
        }

        var playbackHighlightRect: CGRect?
        var playbackHighlightColor: UIColor?
        if let playbackHighlightRange = playbackHighlightNSRange(in: text),
           let playbackRect = segmentRectInTextView(textView: textView, nsRange: playbackHighlightRange) {
            playbackHighlightColor = UIColor { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor.systemOrange.withAlphaComponent(0.30)
                    : UIColor.systemOrange.withAlphaComponent(0.22)
            }
            playbackHighlightRect = playbackRect.insetBy(dx: -10, dy: -4)
            coordinator.applyPlaybackAutoscrollIfNeeded(
                to: textView,
                cueIndex: activePlaybackCueIndex,
                targetRect: playbackRect
            )
        } else {
            coordinator.clearPlaybackAutoscrollState()
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

        // Ruby-spacing kern pass: measure each segment's envelope (kanji advance box ∪
        // predicted ruby frame), detect same-line neighbor overlaps, and apply the overlap
        // as trailing kern on the last UTF-16 unit of the first segment of each pair.
        // Gated on didRenderText so scroll-driven renders skip it entirely — kerns are
        // already committed to textStorage from the text-change pass and don't need
        // recomputing. Re-running on every scroll would do O(N) firstRect queries per
        // frame and, if any overlap is still detected, compound the kerns on each tick.
        if didRenderText, isRubySpacingEnabled {
            let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            let baseFont = UIFont.systemFont(ofSize: textSize)
            struct EnvelopeEntry {
                let text: String
                let leftX: CGFloat
                let rightX: CGFloat
                let lineY: CGFloat
                let nsRange: NSRange
            }
            // Recomputes every segment's envelope (kanji advance box ∪ predicted ruby frame)
            // from current TextKit geometry. Called once before kern application and once
            // after, so each pass sees live positions rather than stale measurements.
            let computeEntries: () -> [EnvelopeEntry] = {
                var result: [EnvelopeEntry] = []
                for segmentRange in segmentationRanges {
                    let segmentText = String(text[segmentRange])
                    guard !segmentText.unicodeScalars.allSatisfy({ ignoredScalars.contains($0) }) else { continue }
                    let nsRange = NSRange(segmentRange, in: text)
                    guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
                    guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else { continue }
                    // Compute the envelope's right edge as segmentRect.minX + measured
                    // surface width (with the configured global kerning). This pins the right
                    // edge to the segment's intrinsic glyph run — no trailing ruby-spacing kern
                    // baked in — so applying kern to A's last char moves only B's leftX, and
                    // overlap reduces by the full kern amount.
                    let surfaceString = String(text[segmentRange])
                    let measuredWidth = measureTextWidth(surfaceString, font: UIFont.systemFont(ofSize: textSize), kerning: kerning)
                    var envelopeMinX = segmentRect.minX
                    var envelopeMaxX = segmentRect.minX + measuredWidth
                    if let furigana = furiganaBySegmentLocation[nsRange.location],
                       !furigana.isEmpty,
                       let length = furiganaLengthBySegmentLocation[nsRange.location], length > 0,
                       let surfaceRange = Range(NSRange(location: nsRange.location, length: length), in: text),
                       let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                           surface: String(text[surfaceRange]), reading: furigana
                       ) {
                        let furiganaWidth = measureTextWidth(displayReading, font: UIFont.systemFont(ofSize: textSize * 0.5), kerning: 0)
                        let visualHeadwordWidth = measureTextWidth(String(text[surfaceRange]), font: baseFont, kerning: 0)
                        let kanjiVisualMidX = segmentRect.minX + visualHeadwordWidth / 2
                        let furiganaMinX = kanjiVisualMidX - furiganaWidth / 2
                        let furiganaMaxX = kanjiVisualMidX + furiganaWidth / 2
                        envelopeMinX = min(envelopeMinX, furiganaMinX)
                        envelopeMaxX = max(envelopeMaxX, furiganaMaxX)
                    }
                    result.append(EnvelopeEntry(text: segmentText, leftX: envelopeMinX, rightX: envelopeMaxX, lineY: segmentRect.midY, nsRange: nsRange))
                }
                return result
            }

            let entries = computeEntries()
            var didApplyKern = false
            let textStorage = textView.textStorage
            // Track the last-char ranges we mutated, paired with the prior kern attribute
            // (raw NSNumber? so we can distinguish "absent" from "explicit value") so a
            // post-layout pass can revert any kern that pushed B onto a new line. Without
            // that revert, the trailing kern leaks visible whitespace before B's first
            // glyph at the start of the wrapped line.
            var appliedKernByPairIndex: [Int: (range: NSRange, priorKern: NSNumber?)] = [:]
            for i in 0..<max(0, entries.count - 1) {
                let a = entries[i]
                let b = entries[i + 1]
                guard abs(a.lineY - b.lineY) < 1.0 else { continue }
                guard a.rightX > b.leftX else { continue }
                let overlap = CGFloat(Int(ceil(a.rightX - b.leftX)))
                let lastCharLocation = a.nsRange.location + a.nsRange.length - 1
                let lastCharRange = NSRange(location: lastCharLocation, length: 1)
                guard lastCharLocation >= 0,
                      lastCharLocation + 1 <= textStorage.length else { continue }
                let existingRaw = textStorage.attribute(.kern, at: lastCharLocation, effectiveRange: nil)
                let priorKern = existingRaw as? NSNumber
                let existing = CGFloat(priorKern?.doubleValue ?? kerning)
                let newKern = existing + overlap
                textStorage.addAttribute(.kern, value: newKern, range: lastCharRange)
                appliedKernByPairIndex[i] = (lastCharRange, priorKern)
                didApplyKern = true
            }
            if didApplyKern {
                // Attribute-only edits don't always invalidate cached TextKit 2 layout
                // fragments, so force invalidation of the full document range before
                // re-running layout — otherwise the re-measure below reads stale glyph
                // positions and the applied kern looks like it only partially shifted B.
                if let tlm = textView.textLayoutManager,
                   let docRange = tlm.textContentManager?.documentRange {
                    tlm.invalidateLayout(for: docRange)
                }
                ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)
                // Revert any kern that pushed B onto a different line: the trailing kern would
                // otherwise leak visible whitespace before B at the start of the wrapped line.
                let postEntriesForRevert = computeEntries()
                if postEntriesForRevert.count == entries.count {
                    var didRevert = false
                    for (pairIndex, applied) in appliedKernByPairIndex {
                        guard pairIndex + 1 < postEntriesForRevert.count else { continue }
                        let aPost = postEntriesForRevert[pairIndex]
                        let bPost = postEntriesForRevert[pairIndex + 1]
                        if abs(aPost.lineY - bPost.lineY) >= 1.0 {
                            // Restore the exact prior kern: re-apply the original NSNumber when
                            // present, or remove the attribute entirely when it was absent —
                            // overwriting with the global `kerning` would clobber any pre-existing
                            // styling-applied kern on this character.
                            if let priorKern = applied.priorKern {
                                textStorage.addAttribute(.kern, value: priorKern, range: applied.range)
                            } else {
                                textStorage.removeAttribute(.kern, range: applied.range)
                            }
                            didRevert = true
                        }
                    }
                    if didRevert {
                        if let tlm = textView.textLayoutManager,
                           let docRange = tlm.textContentManager?.documentRange {
                            tlm.invalidateLayout(for: docRange)
                        }
                        ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)
                    }
                }
                // Post-kern diagnostic: recompute envelopes and log residuals. Only runs
                // when envelope-rects debug flag is on — in production this is a full
                // O(N) firstRect pass that blocks the main thread for no visual benefit.
                if debugEnvelopeRects {
                    let postEntries = computeEntries()
                    for i in 0..<max(0, postEntries.count - 1) {
                        let a = postEntries[i]
                        let b = postEntries[i + 1]
                        guard abs(a.lineY - b.lineY) < 1.0 else { continue }
                        if a.rightX > b.leftX {
                            NSLog("[envelope-overlap-post] first=%@ next=%@ overlap=%d",
                                  a.text, b.text, Int(ceil(a.rightX - b.leftX)))
                        }
                    }
                }
            }
        }

        var furiganaStrings: [String] = []
        var furiganaFrames: [CGRect] = []
        var furiganaColors: [UIColor] = []
        // Furigana frames keyed by segment UTF-16 location, used by the debug loops below.
        var furiganaFrameByLocation: [Int: CGRect] = [:]

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
                guard
                    let surfaceRange = Range(nsRange, in: text),
                    let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                        surface: String(text[surfaceRange]),
                        reading: furigana
                    )
                else {
                    continue
                }
                if blankSelectedSegmentLocation == selectedSegmentLocation,
                   let selectedSegmentRange,
                   NSIntersectionRange(nsRange, selectedSegmentRange).length > 0 {
                    continue
                }
                guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else {
                    continue
                }

                let furiganaWidth = measureTextWidth(displayReading, font: furiganaFont, kerning: 0)
                // Measure the kanji's visual width from TextKit's own last-char rect so the
                // center accounts for global kerning between multi-char segments (嗚呼 etc.)
                // without including the trailing kern we apply for ruby spacing — that kern
                // sits AFTER the last char, so querying the last char's rect alone excludes it.
                let kanjiLastCharLocation = nsRange.location + nsRange.length - 1
                let kanjiLastCharRange = NSRange(location: kanjiLastCharLocation, length: 1)
                let kanjiVisualMaxX = segmentRectInTextView(textView: textView, nsRange: kanjiLastCharRange)?.maxX
                    ?? segmentRect.maxX
                let kanjiVisualWidth = kanjiVisualMaxX - segmentRect.minX
                let kanjiVisualMidX = segmentRect.minX + kanjiVisualWidth / 2
                let furiganaX = kanjiVisualMidX - furiganaWidth / 2
                let furiganaFrame = CGRect(
                    x: furiganaX,
                    y: max(segmentRect.minY - furiganaFont.lineHeight - furiganaGap, 0),
                    width: furiganaWidth,
                    height: furiganaFont.lineHeight
                )
                furiganaStrings.append(displayReading)
                furiganaFrames.append(furiganaFrame)
                furiganaColors.append(textStylePayload.segmentForegroundByLocation[location] ?? .secondaryLabel)
                furiganaFrameByLocation[location] = furiganaFrame
            }
        }

        // Collects debug geometry for every non-whitespace/punctuation segment:
        // headword rects, bisectors, and envelope rects. Runs whenever any of the three
        // debug flags is on so all three share a single layout pass over the segments.
        var debugCollectedHeadwordRects: [CGRect] = []
        var debugCollectedHeadwordColors: [UIColor] = []
        var bisectorHeadwordMidXs: [CGFloat] = []
        var bisectorHeadwordRects: [CGRect] = []
        var bisectorFuriganaRects: [CGRect] = []
        var debugEnvelopeRectsList: [CGRect] = []
        let needsDebugSegmentPass = debugHeadwordRects || debugBisectors || debugEnvelopeRects
        if needsDebugSegmentPass {
            let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            for segmentRange in segmentationRanges {
                let segmentText = String(text[segmentRange])
                guard !segmentText.unicodeScalars.allSatisfy({ ignoredScalars.contains($0) }) else { continue }
                let nsRange = NSRange(segmentRange, in: text)
                guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
                guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else { continue }
                let segmentColor = textStylePayload.segmentForegroundByLocation[nsRange.location] ?? .label

                if debugHeadwordRects {
                    debugCollectedHeadwordRects.append(segmentRect)
                    debugCollectedHeadwordColors.append(segmentColor)
                }

                if debugBisectors {
                    // The headword bisector must span only the kanji the furigana covers,
                    // not the entire segment — e.g. for "食べる" the bisector sits over "食",
                    // because that is what the furigana "た" is centered on.
                    let segStart = nsRange.location
                    let segEnd = nsRange.location + nsRange.length
                    let kanjiLocations = furiganaBySegmentLocation.keys
                        .filter { key in
                            guard let length = furiganaLengthBySegmentLocation[key], length > 0 else { return false }
                            return key >= segStart && key + length <= segEnd
                        }
                        .sorted()
                    for kanjiLocation in kanjiLocations {
                        guard
                            let kanjiLength = furiganaLengthBySegmentLocation[kanjiLocation],
                            let kanjiRect = segmentRectInTextView(
                                textView: textView,
                                nsRange: NSRange(location: kanjiLocation, length: kanjiLength)
                            )
                        else { continue }
                        // Visual midX derived from TextKit's own last-char rect so the bisector
                        // uses the same centering math as the furigana placement — otherwise
                        // multi-char kanji whose global kerning widens the rendered width are
                        // reported as misaligned even when the ruby is correctly centered.
                        let kanjiLastCharLoc = kanjiLocation + kanjiLength - 1
                        let kanjiLastCharRange = NSRange(location: kanjiLastCharLoc, length: 1)
                        let kanjiVisualMaxX = segmentRectInTextView(textView: textView, nsRange: kanjiLastCharRange)?.maxX
                            ?? kanjiRect.maxX
                        let kanjiVisualMidX = kanjiRect.minX + (kanjiVisualMaxX - kanjiRect.minX) / 2
                        let furiganaFrame = furiganaFrameByLocation[kanjiLocation] ?? .zero
                        bisectorHeadwordMidXs.append(kanjiVisualMidX)
                        bisectorHeadwordRects.append(kanjiRect)
                        bisectorFuriganaRects.append(furiganaFrame)
                    }
                }

                if debugEnvelopeRects {
                    // Envelope = visual bounds of kanji advance box ∪ ruby frame. Size is a
                    // property of the segment's content; ruby-spacing only changes where the
                    // envelope sits, not how large it is.
                    let furiganaFrame = furiganaFrameByLocation[nsRange.location]
                    if let furiganaFrame {
                        let envelopeMinX = min(segmentRect.minX, furiganaFrame.minX)
                        let envelopeMaxX = max(segmentRect.maxX, furiganaFrame.maxX)
                        debugEnvelopeRectsList.append(CGRect(
                            x: envelopeMinX,
                            y: furiganaFrame.minY,
                            width: envelopeMaxX - envelopeMinX,
                            height: segmentRect.maxY - furiganaFrame.minY
                        ))
                    } else {
                        debugEnvelopeRectsList.append(segmentRect)
                    }
                }
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

        // If furigana data was present but no frames were produced, the text layout wasn't ready
        // (e.g. bounds were zero on first render or during a transient collapse while a SwiftUI
        // Form scrolls a row offscreen). Skip the overlay update entirely so the prior valid
        // overlay isn't clobbered with empty data, and don't mark as rendered so the replay
        // triggered by FuriganaRendererTextView.onFirstLayoutResolved retries with a real frame.
        if !furiganaBySegmentLocation.isEmpty && furiganaStrings.isEmpty && textView.bounds.width == 0 {
            return
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
            debugFuriganaLineBandRects: debugFuriganaLineBandRects,
            debugBisectorsEnabled: debugBisectors,
            debugBisectorHeadwordMidXs: bisectorHeadwordMidXs,
            debugBisectorHeadwordRects: bisectorHeadwordRects,
            debugBisectorFuriganaRects: bisectorFuriganaRects,
            debugEnvelopeRectsEnabled: debugEnvelopeRects,
            debugEnvelopeRects: debugEnvelopeRectsList,
            debugLeftInsetGuideX: debugLeftInsetGuide ? textView.textContainerInset.left : nil
        )

        if debugLeftInsetGuide { logLeftInsetGuide(textView: textView) }
        coordinator.markFirstOverlayApplyIfNeeded(furiganaCount: furiganaStrings.count)

        guard isVisualEnhancementsEnabled || selectedSegmentRect != nil || illegalBoundaryRect != nil else {
            coordinator.markRendered(signature: renderSignature)
            return
        }

        coordinator.markRendered(signature: renderSignature)
    }

}
