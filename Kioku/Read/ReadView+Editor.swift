import SwiftUI
import UIKit

// Reference-type cache for the favorited-highlight computation. Held by @State so it persists
// across `body` re-evaluations; because it's a class, ReadView mutates its fields without writing
// the @State wrapper (which would be illegal during a view update). `signature` is the hash of
// the highlight's inputs at the time `locations` was computed; `lemmaBySurface` memoizes
// per-segment lemma resolution for one text (keyed by `lemmaTextKey`).
//
// `lemmaBySurface` stores only SUCCESSFUL (non-nil) resolutions. Caching a nil here was a bug: the
// first highlight pass can run before the segmenter's deinflection resources are loaded, so a
// conjugated surface (消えて) resolves to nil; with the cache keyed by the unchanging note text,
// that nil stuck for the session and the form never bridged to its saved lemma (消える) — base
// forms highlighted, conjugations never did. Not caching misses means each recompute retries
// until resources are ready.
final class FavoritedHighlightMemo {
    var signature: Int?
    var locations: Set<Int> = []
    // Saved, but only under a note OTHER than the active one — mirrors the extract-list star's
    // hollow-yellow "saved elsewhere" state. Disjoint from `locations` by construction (see
    // computeFavoritedSegmentLocations).
    var elsewhereLocations: Set<Int> = []
    var lemmaTextKey: Int = 0
    var lemmaBySurface: [String: String] = [:]
}

// Reference-type cache for the "hide furigana for known words" computation. Same shape and
// rationale as FavoritedHighlightMemo above: held by @State so it survives body re-evals, and
// the lemma cache is keyed per-text so repeated recomputes (e.g. a review answer changing
// reviewStore.learned) don't re-deinflect the whole note.
final class KnownWordFuriganaMemo {
    var signature: Int?
    var locations: Set<Int> = []
    var lemmaTextKey: Int = 0
    var lemmaBySurface: [String: String] = [:]
}

// Reference-type mirror of the CoreText read view's live scroll offset. The CT renderer reports
// every offset change here instead of into @State, so view-mode scrolling costs no SwiftUI body
// re-eval per frame (each eval re-hashes the whole note for the typography fingerprint). The
// value is snapshotted into `sharedScrollOffsetY` exactly when edit mode is entered — the only
// moment the editor needs it. Held by @State so it survives body re-evaluations (same pattern
// as FavoritedHighlightMemo above).
final class ReadScrollOffsetMemo {
    var value: CGFloat = 0
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
    // UTF-16 locations of segments the extract-words list shows a FILLED star for — saved for
    // the active note, or saved with no note attribution at all (a global save). Mirrors the
    // extract-list star's filled/hollow split (see favoritedElsewhereSegmentLocations for the
    // hollow-yellow "saved elsewhere" counterpart) via the same shared predicate
    // (ComputedSavedWordState.isStarFilled) over the same WordsStore snapshot, grounded in
    // encountered surfaces (+ lemma bridging). So inflected forms light up (消える saved →
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
        ensureFavoritedHighlightComputed()
        return favoritedHighlightMemo.locations
    }

    // UTF-16 locations of segments saved under a note OTHER than the active one — the hollow-
    // yellow "saved elsewhere" star, rendered in-text with its own distinct color
    // (favoritedElsewhereHighlightColor) so a word favorited only in a different note reads as
    // "known, but not part of this note" rather than blending into this note's favorites.
    // Disjoint from favoritedSegmentLocations by construction (isStarFilled and
    // isSavedForOtherNotes can't both be true for the same surface).
    var favoritedElsewhereSegmentLocations: Set<Int> {
        ensureFavoritedHighlightComputed()
        return favoritedHighlightMemo.elsewhereLocations
    }

    // Shared memo-check for both favorited-location computed vars above — recomputes at most
    // once per signature change regardless of which (or both) properties are read this pass.
    private func ensureFavoritedHighlightComputed() {
        guard isFavoritedHighlightEnabled else {
            favoritedHighlightMemo.signature = nil
            favoritedHighlightMemo.locations = []
            favoritedHighlightMemo.elsewhereLocations = []
            return
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
        if favoritedHighlightMemo.signature == signature {
            return
        }

        let (locations, elsewhereLocations) = computeFavoritedSegmentLocations()
        favoritedHighlightMemo.signature = signature
        favoritedHighlightMemo.locations = locations
        favoritedHighlightMemo.elsewhereLocations = elsewhereLocations
    }

    // The heavy computation behind the favorited-location properties, run only on a memo miss.
    private func computeFavoritedSegmentLocations() -> (locations: Set<Int>, elsewhereLocations: Set<Int>) {
        // Per-segment lemma resolution is the dominant cost; reuse it across recomputes for the same
        // text so toggling a favorite doesn't re-deinflect the whole note.
        let textKey = text.hashValue
        if favoritedHighlightMemo.lemmaTextKey != textKey {
            favoritedHighlightMemo.lemmaTextKey = textKey
            favoritedHighlightMemo.lemmaBySurface = [:]
        }
        let resolver: (String) -> String? = { [segmenter, favoritedHighlightMemo] surface in
            if let cached = favoritedHighlightMemo.lemmaBySurface[surface] { return cached }
            let value = segmenter.preferredLemma(for: surface)
            // Cache only successful resolutions — a nil here usually means resources weren't ready
            // yet, and caching it would freeze a conjugated surface as "no lemma" for the session.
            if let value { favoritedHighlightMemo.lemmaBySurface[surface] = value }
            return value
        }

        let (state, _) = SegmentListView.computeSavedWordState(
            entries: wordsStore.words,
            lemmaResolver: resolver,
            lemmaCache: [:]
        )
        guard state.savedWordSurfaces.isEmpty == false else { return ([], []) }

        let ns = text as NSString
        var locations = Set<Int>()
        var elsewhereLocations = Set<Int>()
        var verdictBySurface: [String: (filled: Bool, elsewhere: Bool)] = [:]
        for range in segmentRanges {
            let nsRange = NSRange(range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
            let surface = ns.substring(with: nsRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let verdict = verdictBySurface[surface] ?? {
                let filled = state.isStarFilled(surface, noteID: activeNoteID, lemmaResolver: resolver)
                let elsewhere = filled ? false : state.isSavedForOtherNotes(surface, noteID: activeNoteID, lemmaResolver: resolver)
                let v = (filled: filled, elsewhere: elsewhere)
                verdictBySurface[surface] = v
                return v
            }()
            if verdict.filled { locations.insert(nsRange.location) }
            else if verdict.elsewhere { elsewhereLocations.insert(nsRange.location) }
        }
        return (locations, elsewhereLocations)
    }

    // UTF-16 locations of segments whose word is marked learned or mastered (ReviewStore),
    // when the "hide furigana for known words" toggle is on — the Read-tab display option
    // that lets a reader stop seeing readings for words they already know. Memoized the same
    // way as favoritedSegmentLocations above: `body` re-evaluates far more often than the
    // inputs (wordsStore.words, reviewStore's learned/mastered sets, segmentation) actually
    // change, so a signature check skips the per-segment lemma-bridging sweep on a memo hit.
    var furiganaSuppressedForKnownWordsSegmentLocations: Set<Int> {
        ensureKnownWordFuriganaComputed()
        return knownWordFuriganaMemo.locations
    }

    // Shared memo-check for furiganaSuppressedForKnownWordsSegmentLocations — recomputes at
    // most once per signature change, mirroring ensureFavoritedHighlightComputed above.
    private func ensureKnownWordFuriganaComputed() {
        guard isFuriganaHiddenForKnownWords else {
            knownWordFuriganaMemo.signature = nil
            knownWordFuriganaMemo.locations = []
            return
        }

        var hasher = Hasher()
        hasher.combine(activeNoteID)
        hasher.combine(segmentRanges.count)
        if let first = segmentRanges.first { hasher.combine(NSRange(first, in: text).location) }
        if let last = segmentRanges.last { hasher.combine(NSRange(last, in: text).location) }
        for word in wordsStore.words {
            hasher.combine(word.canonicalEntryID)
            for surface in word.encounteredSurfaces.sorted() { hasher.combine(surface) }
        }
        for id in reviewStore.learned.sorted() { hasher.combine(id) }
        for id in reviewStore.mastered.sorted() { hasher.combine(id) }
        let signature = hasher.finalize()
        if knownWordFuriganaMemo.signature == signature {
            return
        }

        knownWordFuriganaMemo.signature = signature
        knownWordFuriganaMemo.locations = computeFuriganaSuppressedForKnownWordsSegmentLocations()
    }

    // The heavy computation behind furiganaSuppressedForKnownWordsSegmentLocations, run only
    // on a memo miss. Resolves each segment's surface to a canonicalEntryID via the saved
    // words' encountered-surface sets (lemma-bridged, same technique as the favorited-glow
    // computation above), then checks that entry against ReviewStore's learned/mastered sets.
    // Words that were never saved have no canonicalEntryID to check and are left alone.
    private func computeFuriganaSuppressedForKnownWordsSegmentLocations() -> Set<Int> {
        guard reviewStore.learned.isEmpty == false || reviewStore.mastered.isEmpty == false else {
            return []
        }

        var entryIDBySurface: [String: Int64] = [:]
        for word in wordsStore.words {
            entryIDBySurface[word.surface] = word.canonicalEntryID
            for surface in word.encounteredSurfaces {
                entryIDBySurface[surface] = word.canonicalEntryID
            }
        }
        guard entryIDBySurface.isEmpty == false else { return [] }

        let textKey = text.hashValue
        if knownWordFuriganaMemo.lemmaTextKey != textKey {
            knownWordFuriganaMemo.lemmaTextKey = textKey
            knownWordFuriganaMemo.lemmaBySurface = [:]
        }
        let resolveLemma: (String) -> String? = { [segmenter, knownWordFuriganaMemo] surface in
            if let cached = knownWordFuriganaMemo.lemmaBySurface[surface] { return cached }
            let value = segmenter.preferredLemma(for: surface)
            if let value { knownWordFuriganaMemo.lemmaBySurface[surface] = value }
            return value
        }

        let ns = text as NSString
        var locations = Set<Int>()
        var isKnownBySurface: [String: Bool] = [:]
        for range in segmentRanges {
            let nsRange = NSRange(range, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
            let surface = ns.substring(with: nsRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard surface.isEmpty == false else { continue }

            let isKnown = isKnownBySurface[surface] ?? {
                let entryID = entryIDBySurface[surface] ?? resolveLemma(surface).flatMap { entryIDBySurface[$0] }
                let value = entryID.map { reviewStore.learned.contains($0) || reviewStore.mastered.contains($0) } ?? false
                isKnownBySurface[surface] = value
                return value
            }()

            if isKnown {
                locations.insert(nsRange.location)
            }
        }
        return locations
    }

    // Furigana maps actually handed to the renderers: gated by the master Furigana toggle,
    // and with entries dropped for segments whose word is suppressed by the "hide furigana
    // for known words" setting. Computed once per body pass and reused at all three renderer
    // call sites below (CoreText, FuriganaTextRenderer, RichTextEditor) so the read and edit
    // surfaces never disagree about which readings are showing.
    var displayedFuriganaBySegmentLocation: [Int: String] {
        guard (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible else { return [:] }
        return furiganaExcludingKnownWordSuppressions(furiganaBySegmentLocation)
    }

    var displayedFuriganaLengthBySegmentLocation: [Int: Int] {
        guard (readResourcesReady || hasRendererSegmentation) && isFuriganaVisible else { return [:] }
        return furiganaExcludingKnownWordSuppressions(furiganaLengthBySegmentLocation)
    }

    // Shared filter behind both displayed* properties above, so the "hide furigana for known
    // words" exclusion can't drift out of sync between the reading map and the length map.
    private func furiganaExcludingKnownWordSuppressions<Value>(_ map: [Int: Value]) -> [Int: Value] {
        let suppressed = furiganaSuppressedForKnownWordsSegmentLocations
        guard suppressed.isEmpty == false else { return map }
        return map.filter { suppressed.contains($0.key) == false }
    }

    var editorView: some View {
        VStack(spacing: 8) {
            ZStack {
                if true /* useCoreTextRenderer — toggle disabled; CT is the only path */ {
                    KiokuCoreTextRendererView(
                        text: text,
                        segmentationRanges: segmentRanges,
                        furiganaBySegmentLocation: displayedFuriganaBySegmentLocation,
                        furiganaLengthBySegmentLocation: displayedFuriganaLengthBySegmentLocation,
                        isFuriganaVisible: isFuriganaVisible,
                        isVisualEnhancementsEnabled: readResourcesReady || hasRendererSegmentation,
                        isColorAlternationEnabled: isColorAlternationEnabled,
                        textSize: $textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning,
                        furiganaGap: CGFloat(furiganaGap),
                        furiganaSizeOverride: customFuriganaSizeEnabled ? CGFloat(furiganaSize) : nil,
                        // Fall through to the active theme's defaults when the user hasn't
                        // enabled Custom Token Colors — keeps the Read view's segment palette
                        // coordinated with the theme picker instead of locked to red/cyan.
                        evenSegmentColor: customTokenColorsEnabled
                            ? (UIColor(hexString: tokenColorAHex) ?? .label)
                            : (UIColor(hexString: Theme.activePalette.defaultTokenColorAHex) ?? .label),
                        oddSegmentColor: customTokenColorsEnabled
                            ? (UIColor(hexString: tokenColorBHex) ?? .secondaryLabel)
                            : (UIColor(hexString: Theme.activePalette.defaultTokenColorBHex) ?? .secondaryLabel),
                        isLineWrappingEnabled: isLineWrappingEnabled,
                        isRubySpacingEnabled: isRubySpacingEnabled,
                        selectedHighlightRange: resolveSelectedHighlightRange(),
                        playbackHighlightRange: playbackHighlightRangeOverride,
                        // Same gating as the segment colors above — user hex when Custom Token
                        // Colors is on, theme default when off — so the three picker controls
                        // stay coherent and a theme switch flows through.
                        selectionHighlightColor: (customTokenColorsEnabled
                            ? (UIColor(hexString: highlightHex) ?? .systemYellow)
                            : (UIColor(hexString: Theme.activePalette.defaultHighlightHex) ?? .systemYellow)
                        ).withAlphaComponent(0.35),
                        playbackHighlightColor: UIColor.systemBlue.withAlphaComponent(0.20),
                        unknownSegmentLocations: unknownSegmentLocations,
                        isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                        unknownSegmentColor: .label,
                        changedSegmentLocations: pendingLLMChangedLocations,
                        changedReadingLocations: pendingLLMChangedReadingLocations,
                        inFlightSegmentLocations: inFlightLineSegmentLocations,
                        favoritedSegmentLocations: favoritedSegmentLocations,
                        isFavoritedHighlightEnabled: isFavoritedHighlightEnabled,
                        favoritedHighlightColor: customTokenColorsEnabled
                            ? (UIColor(hexString: highlightHex) ?? .systemYellow)
                            : (UIColor(hexString: Theme.activePalette.defaultHighlightHex) ?? .systemYellow),
                        favoritedElsewhereSegmentLocations: favoritedElsewhereSegmentLocations,
                        favoritedElsewhereHighlightColor: .systemOrange,
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
                        },
                        // Hidden in edit mode — gate updates so per-keystroke typing doesn't
                        // re-typeset this off-screen renderer (the typing-lag fix).
                        isActive: isEditMode == false,
                        // Edit↔view scroll sync: applied once when edit mode exits (restores
                        // the editor's position); reported into the reference-type memo so
                        // view-mode scrolling stays free of per-frame body re-evals. The memo
                        // is snapshotted into sharedScrollOffsetY on entering edit
                        // (ReadView+Lifecycle's onChange(of: isEditMode)).
                        externalContentOffsetY: sharedScrollOffsetY,
                        onScrollOffsetYChanged: { [readScrollOffsetMemo] newOffsetY in
                            readScrollOffsetMemo.value = newOffsetY
                        },
                        // Reset scroll to the top whenever the active note changes. Keyed on
                        // the note id's hash so each note open is a distinct token transition;
                        // 0 when no note is active.
                        scrollToTopToken: activeNoteID?.hashValue ?? 0
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
                    furiganaBySegmentLocation: displayedFuriganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: displayedFuriganaLengthBySegmentLocation,
                    isVisualEnhancementsEnabled: readResourcesReady || hasRendererSegmentation,
                    isRubySpacingEnabled: isRubySpacingEnabled,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    unknownSegmentLocations: unknownSegmentLocations,
                    changedSegmentLocations: pendingLLMChangedLocations,
                    changedReadingLocations: pendingLLMChangedReadingLocations,
                    inFlightSegmentLocations: inFlightLineSegmentLocations,
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
                    furiganaBySegmentLocation: displayedFuriganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: displayedFuriganaLengthBySegmentLocation,
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
                .fill(
                    japaneseTheme
                        ? (isEditMode ? Theme.surface : Theme.surfaceSecondary)
                        : (isEditMode ? Color(.systemBackground) : Color(.secondarySystemBackground))
                )
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
