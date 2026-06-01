import SwiftUI
import UIKit

// Reference-type cache for the favorited-glow computation. Held by @State so it persists across
// `body` re-evaluations; because it's a class, ReadView mutates its fields without writing the
// @State wrapper (which would be illegal during a view update). `signature` is the hash of the
// glow's inputs at the time `locations` was computed; `lemmaBySurface` memoizes per-segment lemma
// resolution for one text (keyed by `lemmaTextKey`).
final class FavoritedGlowMemo {
    var signature: Int?
    var locations: Set<Int> = []
    var lemmaTextKey: Int = 0
    var lemmaBySurface: [String: String?] = [:]
}

// Editor surface for ReadView: keeps the CoreText reader and the rich-text editor mounted
// together so mode toggles are instant, and exposes the helpers that resolve renderer-side
// segmentation/highlight state.
extension ReadView {
    // True when persisted segmentation has been restored into memory, so the renderer can use it
    // immediately instead of waiting for the trie/lexicon load that drives readResourcesReady.
    // For new or un-segmented notes, segmentRanges is empty until the segmenter computes it, so
    // this stays false and the original gating still applies.
    var hasRendererSegmentation: Bool {
        segmentRanges.isEmpty == false
    }

    // Mirrors FuriganaTextRenderer+Geometry.selectedSegmentNSRange for the CoreText path:
    // prefers the explicit override (set during merge/split previews) over the simple
    // location-based lookup so behavior matches between renderers when an override is active.
    func resolveSelectedHighlightRange() -> NSRange? {
        let ns = text as NSString
        if let override = selectedHighlightRangeOverride,
           override.location != NSNotFound,
           override.length > 0,
           override.upperBound <= ns.length {
            return override
        }
        guard let location = selectedSegmentLocation else { return nil }
        for range in segmentRanges {
            let ns = NSRange(range, in: text)
            if ns.location == location, ns.length > 0 {
                return ns
            }
        }
        return nil
    }

    // Keeps both read and edit renderers mounted so mode toggles are instant.
    // UTF-16 locations of segments the extract-words list shows a FILLED star for — drives the glow.
    // 1:1 with the extract-list stars by construction: both go through the same shared predicate
    // (ComputedSavedWordState.isStarFilled) over the same WordsStore snapshot, grounded in encountered
    // surfaces (+ lemma bridging + note attribution). So inflected forms light up (消える saved →
    // 消えて / 消えてゆく glow) and unfavoriting clears the glow immediately.
    //
    // MEMOIZED: `body` re-evaluates constantly (scroll, playback highlight, selection) but the glow
    // only depends on wordsStore.words, the segmentation, the active note, and the toggle. We hash
    // those into a cheap signature and skip the (expensive) deinflection sweep when nothing relevant
    // changed. The cache lives in a reference type held by @State, so updating it here does NOT trip
    // SwiftUI's "modifying state during view update" (we mutate the object's fields, not the @State
    // wrapper). The per-segment lemma cache persists across recomputes (keyed by text), so even a
    // favorite toggle stays cheap — it re-runs set lookups, not a fresh deinflection pass.
    var favoritedSegmentLocations: Set<Int> {
        guard isFavoritedGlowEnabled else {
            favoritedGlowMemo.signature = nil
            return []
        }

        var hasher = Hasher()
        hasher.combine(activeNoteID)
        hasher.combine(segmentRanges.count)
        if let first = segmentRanges.first { hasher.combine(NSRange(first, in: text).location) }
        if let last = segmentRanges.last { hasher.combine(NSRange(last, in: text).location) }
        for word in wordsStore.words {
            hasher.combine(word.canonicalEntryID)
            for surface in word.encounteredSurfaces.sorted() { hasher.combine(surface) }
            for noteID in word.sourceNoteIDs { hasher.combine(noteID) }
        }
        let signature = hasher.finalize()
        if favoritedGlowMemo.signature == signature {
            return favoritedGlowMemo.locations
        }

        let locations = computeFavoritedSegmentLocations()
        favoritedGlowMemo.signature = signature
        favoritedGlowMemo.locations = locations
        return locations
    }

    // The heavy computation behind `favoritedSegmentLocations`, run only on a memo miss.
    private func computeFavoritedSegmentLocations() -> Set<Int> {
        // Per-segment lemma resolution is the dominant cost; reuse it across recomputes for the same
        // text so toggling a favorite doesn't re-deinflect the whole note.
        let textKey = text.hashValue
        if favoritedGlowMemo.lemmaTextKey != textKey {
            favoritedGlowMemo.lemmaTextKey = textKey
            favoritedGlowMemo.lemmaBySurface = [:]
        }
        let resolver: (String) -> String? = { [segmenter, favoritedGlowMemo] surface in
            if let cached = favoritedGlowMemo.lemmaBySurface[surface] { return cached }
            let value = segmenter.preferredLemma(for: surface)
            favoritedGlowMemo.lemmaBySurface[surface] = value
            return value
        }

        let (state, _) = SegmentListView.computeSavedWordState(
            entries: wordsStore.words,
            lemmaResolver: resolver,
            lemmaCache: [:]
        )
        guard state.savedWordSurfaces.isEmpty == false else { return [] }

        let ns = text as NSString
        var locations = Set<Int>()
        var verdictBySurface: [String: Bool] = [:]
        for range in segmentRanges {
            let nsRange = NSRange(range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
            let surface = ns.substring(with: nsRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let isFilled = verdictBySurface[surface] ?? {
                let v = state.isStarFilled(surface, noteID: activeNoteID, lemmaResolver: resolver)
                verdictBySurface[surface] = v
                return v
            }()
            if isFilled { locations.insert(nsRange.location) }
        }
        return locations
    }

    var editorView: some View {
        VStack(spacing: 8) {
            ZStack {
                if true /* useCoreTextRenderer — toggle disabled; CT is the only path */ {
                    KiokuCoreTextRendererView(
                        text: text,
                        segmentationRanges: segmentRanges,
                        furiganaBySegmentLocation: (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                        furiganaLengthBySegmentLocation: (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                        isFuriganaVisible: isFuriganaVisible,
                        isVisualEnhancementsEnabled: readResourcesReady || hasRendererSegmentation,
                        isColorAlternationEnabled: isColorAlternationEnabled,
                        textSize: $textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning,
                        furiganaGap: CGFloat(furiganaGap),
                        furiganaSizeOverride: customFuriganaSizeEnabled ? CGFloat(furiganaSize) : nil,
                        evenSegmentColor: customTokenColorsEnabled
                            ? (UIColor(hexString: tokenColorAHex) ?? .label)
                            : UIColor { tc in tc.userInterfaceStyle == .dark ? .systemOrange : .systemRed },
                        oddSegmentColor: customTokenColorsEnabled
                            ? (UIColor(hexString: tokenColorBHex) ?? .secondaryLabel)
                            : UIColor { tc in tc.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo },
                        isLineWrappingEnabled: isLineWrappingEnabled,
                        isRubySpacingEnabled: isRubySpacingEnabled,
                        selectedHighlightRange: resolveSelectedHighlightRange(),
                        playbackHighlightRange: playbackHighlightRangeOverride,
                        selectionHighlightColor: (UIColor(hexString: highlightHex) ?? .systemYellow).withAlphaComponent(0.35),
                        playbackHighlightColor: UIColor.systemBlue.withAlphaComponent(0.20),
                        unknownSegmentLocations: unknownSegmentLocations,
                        isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                        unknownSegmentColor: .label,
                        changedSegmentLocations: pendingLLMChangedLocations,
                        changedReadingLocations: pendingLLMChangedReadingLocations,
                        favoritedSegmentLocations: favoritedSegmentLocations,
                        isFavoritedGlowEnabled: isFavoritedGlowEnabled,
                        favoritedGlowColor: UIColor(hexString: highlightHex) ?? .systemYellow,
                        debugFlags: KiokuDebugOverlayView.Flags(
                            headwordRects: debugHeadwordRects,
                            furiganaRects: debugFuriganaRects,
                            envelopeRects: debugEnvelopeRects,
                            headwordBisectors: debugBisectorHeadword,
                            furiganaBisectors: debugBisectorFurigana,
                            headwordLineBands: debugHeadwordLineBands,
                            furiganaLineBands: debugFuriganaLineBands,
                            pixelRuler: debugPixelRuler,
                            leftInsetGuide: debugLeftInsetGuide,
                            headwordLineNumbers: debugHeadwordLineNumbers,
                            rubyLineNumbers: debugRubyLineNumbers
                        ),
                        illegalMergeLocation: illegalMergeBoundaryLocation,
                        onSegmentTapped: { location, rect, scrollView in
                            // The CoreText path forwards its underlying KiokuScrollingTextView so
                            // the sheet-visibility scroll helpers (contentInset.bottom for
                            // overscroll, contentOffset adjust) can run against the same scroll
                            // view that owns the rendered text. UIScrollView is a superclass of
                            // UITextView, so handleReadModeSegmentTap accepts either path.
                            handleReadModeSegmentTap(location, tappedSegmentRect: rect, sourceView: scrollView)
                        }
                    )
                    .opacity(isEditMode ? 0 : 1)
                    .allowsHitTesting(isEditMode == false)
                    .animation(.default, value: isEditMode)
                } else {
                FuriganaTextRenderer(
                    isActive: isEditMode == false,
                    isOverlayFrozen: isSheetSwipeTransitionActive,
                    text: text,
                    isLineWrappingEnabled: isLineWrappingEnabled,
                    segmentationRanges: segmentRanges,
                    selectedSegmentLocation: selectedSegmentLocation,
                    blankSelectedSegmentLocation: transientBlankReadingSegmentLocation,
                    selectedHighlightRangeOverride: selectedHighlightRangeOverride,
                    playbackHighlightRangeOverride: playbackHighlightRangeOverride,
                    activePlaybackCueIndex: activePlaybackCueIndex,
                    illegalMergeBoundaryLocation: illegalMergeBoundaryLocation,
                    furiganaBySegmentLocation: (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                    furiganaLengthBySegmentLocation: (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                    isVisualEnhancementsEnabled: readResourcesReady || hasRendererSegmentation,
                    isRubySpacingEnabled: isRubySpacingEnabled,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    unknownSegmentLocations: unknownSegmentLocations,
                    changedSegmentLocations: pendingLLMChangedLocations,
                    changedReadingLocations: pendingLLMChangedReadingLocations,
                    customEvenSegmentColorHex: customTokenColorsEnabled ? tokenColorAHex : "",
                    customOddSegmentColorHex: customTokenColorsEnabled ? tokenColorBHex : "",
                    debugFuriganaRects: debugFuriganaRects,
                    debugHeadwordRects: debugHeadwordRects,
                    debugHeadwordLineBands: debugHeadwordLineBands,
                    debugFuriganaLineBands: debugFuriganaLineBands,
                    debugBisectorHeadword: debugBisectorHeadword,
                    debugBisectorFurigana: debugBisectorFurigana,
                    debugEnvelopeRects: debugEnvelopeRects,
                    debugLeftInsetGuide: debugLeftInsetGuide,
                    externalContentOffsetY: sharedScrollOffsetY,
                    onScrollOffsetYChanged: { newOffsetY in
                        sharedScrollOffsetY = newOffsetY
                    },
                    onSegmentTapped: { tappedSegmentLocation, tappedSegmentRect, sourceView in
                        handleReadModeSegmentTap(
                            tappedSegmentLocation,
                            tappedSegmentRect: tappedSegmentRect,
                            sourceView: sourceView
                        )
                    },
                    textSize: $textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    furiganaGap: furiganaGap
                )
                .opacity(isEditMode ? 0 : 1)
                .allowsHitTesting(isEditMode == false)
                .animation(.default, value: isEditMode)
                }

                RichTextEditor(
                    text: $text,
                    isLineWrappingEnabled: isLineWrappingEnabled,
                    segmentationRanges: segmentRanges,
                    furiganaBySegmentLocation: (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible ? furiganaBySegmentLocation : [:],
                    furiganaLengthBySegmentLocation: (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
                    isVisualEnhancementsEnabled: readResourcesReady || hasRendererSegmentation,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    segmenter: segmenter,
                    isEditMode: isEditMode,
                    externalContentOffsetY: sharedScrollOffsetY,
                    onScrollOffsetYChanged: { newOffsetY in
                        sharedScrollOffsetY = newOffsetY
                    },
                    textSize: $textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    furiganaGap: furiganaGap,
                    debugHeadwordLineBands: debugHeadwordLineBands,
                    debugFuriganaLineBands: debugFuriganaLineBands
                )
                .opacity(isEditMode ? 1 : 0)
                .allowsHitTesting(isEditMode)
                .animation(.default, value: isEditMode)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isEditMode ? Color(.systemBackground) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isEditMode ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.3),
                    lineWidth: isEditMode ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .animation(.default, value: isEditMode)
        // Disk/mem load-info toast disabled — re-enable by uncommenting this overlay and the
        // showLoadInfoToast(for:) call in ReadView+Persistence.swift.
        // .overlay(alignment: .top) {
        //     if let message = loadInfoToastMessage {
        //         Text(message)
        //             .font(.system(size: 11, weight: .semibold, design: .monospaced))
        //             .foregroundStyle(.white)
        //             .padding(.horizontal, 10)
        //             .padding(.vertical, 5)
        //             .background(Capsule().fill(Color.black.opacity(0.78)))
        //             .padding(.top, 12)
        //             .onTapGesture {
        //                 loadInfoToastClearTask?.cancel()
        //                 loadInfoToastMessage = nil
        //             }
        //             .transition(.opacity.combined(with: .move(edge: .top)))
        //     }
        // }
        // .animation(.easeInOut(duration: 0.18), value: loadInfoToastMessage)
    }
}
