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
    // Headword bisector: vertical line at the kanji-run geometric center.
    // Furigana bisector: vertical line at the ruby string geometric center.
    // Independent toggles so any misalignment between the two is directly visible.
    let debugBisectorHeadword: Bool
    let debugBisectorFurigana: Bool
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
            // Gate scroll-publish callbacks for the duration of this branch AND one extra
            // runloop after, so post-render contentSize fluctuations from the spacing-
            // correction pass don't clamp contentOffset and republish the clamp into
            // sharedScrollOffsetY. The deferred end runs on the next main-loop tick.
            coordinator.beginTextRenderScrollGate()
            DispatchQueue.main.async { [weak coordinator] in
                coordinator?.endTextRenderScrollGate()
            }
            coordinator.markFirstTextRenderIfNeeded()
            // Clear stale exclusion paths before applying new attributed text. Without this,
            // the existing exclusions shift line-start glyphs right during the fresh layout pass
            // so applyLeftInsetExclusionsForWideRuby's `<= lineStartTolerance` check fails on
            // the already-shifted segments, which then clears the exclusions and snaps glyphs
            // back to x=0 — causing visible alignment jitter on every text-change render.
            textView.textContainer.exclusionPaths = []
            // Snapshot the current scroll position BEFORE reassigning attributedText so we can
            // restore it after layout settles — UIScrollView clamps contentOffset.y to 0 during
            // the transient contentSize=0 window between attributedText reassignment and the
            // following ensureTextLayout. Using a local snapshot (not externalContentOffsetY)
            // makes this robust even if a prior bad publish already corrupted sharedScrollOffsetY.
            //
            // Detect deliberate "scroll to top" requests (note load, sheet dismiss) as a
            // *transition* from a non-zero externalContentOffsetY to 0 — NOT the static
            // "value is currently 0" check, which fires every time the user is at the top
            // and would force them back when editing a reading or running any other text-
            // change render.
            let preReassignmentOffsetY = textView.contentOffset.y
            let isExplicitScrollToTop: Bool
            if let last = coordinator.lastObservedExternalOffsetY,
               externalContentOffsetY == 0,
               last > 0.5 {
                isExplicitScrollToTop = true
            } else {
                isExplicitScrollToTop = false
            }
            coordinator.lastObservedExternalOffsetY = externalContentOffsetY
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
            // Restore scroll position. By default, restore the pre-reassignment snapshot —
            // splits/merges and most edits should not move the user's view. The exception is
            // a deliberate scroll-to-top from a note switch (externalContentOffsetY == 0 and
            // we were scrolled), in which case we honor the external request. suppressPublish
            // is true so the layout-driven setContentOffset can't republish a transient clamp.
            let restoreTarget: CGFloat = isExplicitScrollToTop ? 0 : preReassignmentOffsetY
            coordinator.applyExternalScrollIfNeeded(
                to: textView,
                targetOffsetY: restoreTarget,
                suppressPublish: true
            )
            coordinator.markTextRendered(signature: baseTextRenderSignature)
            // The freshly assigned attributedText already carries the latest colors, so the
            // style sig is in sync after a text-change render — record it to avoid a redundant
            // in-place color reapply on the next pass.
            coordinator.markStyleAttributesRendered(signature: makeStyleAttributesSignature())
        } else {
            // Text is unchanged. If only segmentation / per-segment colors changed (split,
            // merge, alternation/highlight toggle, custom color tweak), mutate textStorage's
            // color attributes in place — no attributedText reassignment, no contentSize
            // perturbation, no scroll-jump-to-top.
            let styleSignature = makeStyleAttributesSignature()
            let didApplyStyle = coordinator.shouldRenderStyleAttributes(for: styleSignature)
            if didApplyStyle {
                applyStyleAttributesInPlace(to: textView, payload: textStylePayload)
                coordinator.markStyleAttributesRendered(signature: styleSignature)
            }
            // Layout strategy:
            //   - Style-attributes change (split/merge/alternation toggle) → exhaustive. The
            //     attribute mutation can shift TextKit's internal layout invariants enough that
            //     viewport-only firstRect queries return stale Y values, which manifests as
            //     ruby drifting vertically until the next exhaustive pass runs.
            //   - Pure scroll-only update → viewport-only is enough; the overlay only needs
            //     fresh rects for what's about to be drawn.
            //   - Non-scrolling preview → always exhaustive so the last wrapped line's
            //     fragments are realized for firstRect queries.
            let shouldRunExhaustive = didApplyStyle || !textView.isScrollEnabled
            ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: shouldRunExhaustive)
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
            // so a wider ruby like ちから over 力 isn't clipped on the right. Resolution of the
            // ruby string and the envelope math live in FuriganaSelectedSegmentGeometry so the
            // formula is testable across text-size / spacing variations without standing up a
            // UITextView in the test target.
            let surfaceString = String(text[selectedSurfaceRange])
            var rubyDisplayReading: String?
            if let furigana = furiganaBySegmentLocation[selectedSegmentRange.location],
               !furigana.isEmpty,
               let length = furiganaLengthBySegmentLocation[selectedSegmentRange.location], length > 0,
               let surfaceRange = Range(NSRange(location: selectedSegmentRange.location, length: length), in: text) {
                rubyDisplayReading = FuriganaAttributedString.normalizedDisplayReading(
                    surface: String(text[surfaceRange]), reading: furigana
                )
            }
            let envelope = FuriganaSelectedSegmentGeometry.envelopeRect(
                selectedRect: selectedRect,
                surface: surfaceString,
                furigana: rubyDisplayReading,
                textSize: CGFloat(textSize),
                furiganaGap: CGFloat(furiganaGap)
            )
            // Sanity assertions catch envelope regressions immediately in debug builds.
            // Floating-point round-trips through (selectedRect.minY − furiganaRowHeight) +
            // (selectedRect.height + furiganaRowHeight) can drift by epsilon vs the algebraic
            // identity, so the bottom-edge invariant is implied by the formula and isn't
            // re-asserted here.
            #if DEBUG
            assert(envelope.width > 0 && envelope.height > 0,
                   "selected-segment envelope is empty for surface=\(surfaceString)")
            assert(envelope.minY <= selectedRect.minY + 0.001,
                   "selected-segment envelope must extend above the headword for furigana row")
            #endif
            selectedSegmentRect = envelope
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

        // Single-pass inter-segment spacing correction. For each adjacent same-line pair,
        // measure the visible gap between segment envelopes (kerned glyph extent ∪ ruby frame)
        // and bump trailing .kern on the first segment's last char so the gap lands at
        // (user kerning setting). Runs only on text-change renders — kerns persist on
        // textStorage, so scroll-driven updateUIView calls don't redo the work.
        if didRenderText, isRubySpacingEnabled {
            struct SpacingEnvelope {
                let minX: CGFloat
                let maxX: CGFloat
                let lineY: CGFloat
                let nsRange: NSRange
            }
            let baseFont = UIFont.systemFont(ofSize: textSize)
            let ignoredScalars = CharacterSet.whitespacesAndNewlines
            let computeEnvelopes: () -> [SpacingEnvelope] = {
                var result: [SpacingEnvelope] = []
                for segmentRange in segmentationRanges {
                    let segmentText = String(text[segmentRange])
                    guard !segmentText.unicodeScalars.allSatisfy({ ignoredScalars.contains($0) }) else { continue }
                    let nsRange = NSRange(segmentRange, in: text)
                    guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
                    guard let segRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else { continue }
                    let kernedSegW = kernedVisualWidth(of: segmentText, font: baseFont)
                    var envMinX = segRect.minX
                    var envMaxX = segRect.minX + kernedSegW
                    let segStart = nsRange.location
                    let segEnd = nsRange.location + nsRange.length
                    for (kanjiLoc, reading) in furiganaBySegmentLocation {
                        guard kanjiLoc >= segStart,
                              let kanjiLen = furiganaLengthBySegmentLocation[kanjiLoc],
                              kanjiLen > 0,
                              kanjiLoc + kanjiLen <= segEnd,
                              !reading.isEmpty,
                              let surfaceRange = Range(NSRange(location: kanjiLoc, length: kanjiLen), in: text),
                              let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                                  surface: String(text[surfaceRange]), reading: reading
                              ) else { continue }
                        let furiW = measureTextWidth(displayReading, font: furiganaFont, kerning: 0)
                        let kanjiFirstCharRange = NSRange(location: kanjiLoc, length: 1)
                        let kanjiMinX = segmentRectInTextView(textView: textView, nsRange: kanjiFirstCharRange)?.minX ?? segRect.minX
                        let kernedKanjiW = kernedVisualWidth(of: String(text[surfaceRange]), font: baseFont)
                        let kanjiMidX = kanjiMinX + kernedKanjiW / 2
                        envMinX = min(envMinX, kanjiMidX - furiW / 2)
                        envMaxX = max(envMaxX, kanjiMidX + furiW / 2)
                    }
                    result.append(SpacingEnvelope(minX: envMinX, maxX: envMaxX, lineY: segRect.midY, nsRange: nsRange))
                }
                return result
            }

            let entries = computeEnvelopes()
            let textStorage = textView.textStorage
            let desiredGap = CGFloat(kerning)
            // (pairIndex into entries, last-char range, prior kern attribute) — pairIndex lets
            // the revert pass match post-layout entries to pre-layout pairs for line-wrap checks.
            var applied: [(pairIndex: Int, range: NSRange, priorKern: NSNumber?)] = []
            for i in 0..<max(0, entries.count - 1) {
                let a = entries[i]
                let b = entries[i + 1]
                guard abs(a.lineY - b.lineY) < 1.0 else { continue }
                let measured = b.minX - a.maxX
                let delta = desiredGap - measured
                guard abs(delta) >= 0.05 else { continue }
                let lastLoc = a.nsRange.location + a.nsRange.length - 1
                guard lastLoc >= 0, lastLoc + 1 <= textStorage.length else { continue }
                let lastRange = NSRange(location: lastLoc, length: 1)
                let priorRaw = textStorage.attribute(.kern, at: lastLoc, effectiveRange: nil)
                let priorKern = priorRaw as? NSNumber
                let existing = CGFloat(priorKern?.doubleValue ?? kerning)
                textStorage.addAttribute(.kern, value: existing + delta, range: lastRange)
                applied.append((i, lastRange, priorKern))
            }
            if !applied.isEmpty {
                if let tlm = textView.textLayoutManager,
                   let docRange = tlm.textContentManager?.documentRange {
                    tlm.invalidateLayout(for: docRange)
                }
                ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)
                // Revert any kern that pushed a pair across a line break or made a segment
                // disappear from firstRect queries (off-bounds). Two signals:
                //   • postEntries.count < entries.count → some segment fell off-bounds; revert all.
                //   • postEntries[i].lineY != postEntries[i+1].lineY for an applied pair → that
                //     specific kern caused the wrap; revert just that one.
                let postEntries = computeEnvelopes()
                let lostSegments = postEntries.count < entries.count
                var didRevert = false
                for entry in applied {
                    let shouldRevert: Bool
                    if lostSegments {
                        shouldRevert = true
                    } else if entry.pairIndex + 1 < postEntries.count {
                        shouldRevert = abs(postEntries[entry.pairIndex].lineY - postEntries[entry.pairIndex + 1].lineY) >= 1.0
                    } else {
                        shouldRevert = true
                    }
                    guard shouldRevert else { continue }
                    if let prior = entry.priorKern {
                        textStorage.addAttribute(.kern, value: prior, range: entry.range)
                    } else {
                        textStorage.removeAttribute(.kern, range: entry.range)
                    }
                    didRevert = true
                }
                if didRevert {
                    if let tlm = textView.textLayoutManager,
                       let docRange = tlm.textContentManager?.documentRange {
                        tlm.invalidateLayout(for: docRange)
                    }
                    ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)
                }
            }
        }

        var furiganaStrings: [String] = []
        var furiganaFrames: [CGRect] = []
        var furiganaColors: [UIColor] = []
        // Furigana frames keyed by segment UTF-16 location, used by the debug loops below.
        var furiganaFrameByLocation: [Int: CGRect] = [:]

        // Force exhaustive layout once before any per-segment firstRect query. Without this,
        // segmentRectInTextView's own ensureTextLayout(exhaustive: false) only realizes the
        // viewport, so segments on lines past the current bounds (e.g. the last wrapped line
        // of a non-scrolling preview, or a line the kern pass nudged off-viewport) return
        // nil firstRects and silently drop their ruby + envelope + headword rect — the
        // visible symptom is "the last segment of the document has no overlays".
        ensureTextLayout(for: textView, coordinator: coordinator, exhaustive: true)

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
                // Anchor at the first char's TextKit minX (which already reflects exclusion-path
                // shifts and line-start offsets) and add the kerned glyph extent so the ruby
                // centers on the actual headword body. Using the last-char rect's maxX would
                // include the trailing post-layout kern we add to push neighboring segments apart
                // — that pads the rect into inter-segment whitespace and pulls the midX right.
                // Kerned extent = unkerned glyph width + (charCount - 1) * user kerning, which
                // matches what the textView actually renders when the user's kerning > 0.
                let baseFont = UIFont.systemFont(ofSize: textSize)
                let kanjiFirstCharRange = NSRange(location: nsRange.location, length: 1)
                let kanjiVisualMinX = segmentRectInTextView(textView: textView, nsRange: kanjiFirstCharRange)?.minX
                    ?? segmentRect.minX
                let headwordSurface = String(text[surfaceRange])
                let kernedHeadwordWidth = kernedVisualWidth(of: headwordSurface, font: baseFont)
                let kanjiVisualMidX = kanjiVisualMinX + kernedHeadwordWidth / 2
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

        // Collects debug geometry for every non-whitespace segment (punctuation included so
        // its envelopes and bisectors are visible during spacing diagnosis):
        // headword rects, bisectors, and envelope rects. Runs whenever any of the three
        // debug flags is on so all three share a single layout pass over the segments.
        var debugCollectedHeadwordRects: [CGRect] = []
        var debugCollectedHeadwordColors: [UIColor] = []
        var bisectorHeadwordMidXs: [CGFloat] = []
        var bisectorHeadwordRects: [CGRect] = []
        var bisectorFuriganaRects: [CGRect] = []
        var debugEnvelopeRectsList: [CGRect] = []
        var debugEnvelopeTexts: [String] = []
        let needsDebugSegmentPass = debugHeadwordRects || debugBisectorHeadword || debugBisectorFurigana || debugEnvelopeRects
        if needsDebugSegmentPass {
            let ignoredScalars = CharacterSet.whitespacesAndNewlines
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

                if debugBisectorHeadword || debugBisectorFurigana {
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
                        // One bisector per kanji run at the run's geometric center, computed by
                        // anchoring at the first char's TextKit minX (already reflects exclusion
                        // paths and line-start offsets) plus half the kerned glyph extent.
                        let bisectorBaseFont = UIFont.systemFont(ofSize: textSize)
                        let kanjiFirstCharRange = NSRange(location: kanjiLocation, length: 1)
                        let kanjiVisualMinX = segmentRectInTextView(textView: textView, nsRange: kanjiFirstCharRange)?.minX
                            ?? kanjiRect.minX
                        let kanjiSurfaceForMid: String
                        if let surfaceRange = Range(NSRange(location: kanjiLocation, length: kanjiLength), in: text) {
                            kanjiSurfaceForMid = String(text[surfaceRange])
                        } else {
                            kanjiSurfaceForMid = ""
                        }
                        let kernedKanjiWidth = kernedVisualWidth(of: kanjiSurfaceForMid, font: bisectorBaseFont)
                        let kanjiVisualMidX = kanjiVisualMinX + kernedKanjiWidth / 2
                        let furiganaFrame = furiganaFrameByLocation[kanjiLocation] ?? .zero
                        bisectorHeadwordMidXs.append(kanjiVisualMidX)
                        bisectorHeadwordRects.append(kanjiRect)
                        bisectorFuriganaRects.append(furiganaFrame)
                    }
                }

                if debugEnvelopeRects {
                    // One envelope per segment, encompassing every rendered glyph in the
                    // segment ∪ every ruby frame attached to a kanji run inside it. The
                    // horizontal extent uses kernedVisualWidth so trailing post-layout kern
                    // applied to the segment's last char (to push the next segment over)
                    // doesn't pad the envelope into inter-segment whitespace.
                    let envelopeBaseFont = UIFont.systemFont(ofSize: textSize)
                    let kernedSegmentWidth = kernedVisualWidth(of: segmentText, font: envelopeBaseFont)
                    var envelopeMinX = segmentRect.minX
                    var envelopeMaxX = segmentRect.minX + kernedSegmentWidth
                    var envelopeMinY = segmentRect.minY

                    let segStart = nsRange.location
                    let segEnd = nsRange.location + nsRange.length
                    for (kanjiLocation, frame) in furiganaFrameByLocation {
                        guard let kanjiLength = furiganaLengthBySegmentLocation[kanjiLocation],
                              kanjiLength > 0,
                              kanjiLocation >= segStart,
                              kanjiLocation + kanjiLength <= segEnd
                        else { continue }
                        envelopeMinX = min(envelopeMinX, frame.minX)
                        envelopeMaxX = max(envelopeMaxX, frame.maxX)
                        envelopeMinY = min(envelopeMinY, frame.minY)
                    }

                    debugEnvelopeRectsList.append(CGRect(
                        x: envelopeMinX,
                        y: envelopeMinY,
                        width: envelopeMaxX - envelopeMinX,
                        height: segmentRect.maxY - envelopeMinY
                    ))
                    debugEnvelopeTexts.append(segmentText)
                }
            }

            // Per-frame diagnostic for inter-segment spacing. For each adjacent pair on the
            // same line, log the signed gap (envelope[i].maxX → envelope[i+1].minX). Negative
            // means visible overlap; large positive means a phantom space. Replaces the
            // [envelope-overlap-post] log that lived inside the removed iterative kern pass.
            if debugEnvelopeRects, debugEnvelopeRectsList.count >= 2 {
                for i in 0..<(debugEnvelopeRectsList.count - 1) {
                    let a = debugEnvelopeRectsList[i]
                    let b = debugEnvelopeRectsList[i + 1]
                    guard abs(a.midY - b.midY) < 1.0 else { continue }
                    let gap = b.minX - a.maxX
                    guard abs(gap) >= 0.05 else { continue }
                    NSLog("[envelope-gap] %@ → %@ gap=%.1fpt", debugEnvelopeTexts[i], debugEnvelopeTexts[i + 1], Double(gap))
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
            debugBisectorHeadwordEnabled: debugBisectorHeadword,
            debugBisectorFuriganaEnabled: debugBisectorFurigana,
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
