import SwiftUI
import UIKit

// SwiftUI bridge for the experimental CoreText Read renderer. Mounted in place of
// `FuriganaTextRenderer` when DebugSettings.useCoreTextRenderer is on.
//
// Scope of this first integration step: render plain text (no segment overlays, no
// per-segment ruby attributes — CTRubyAnnotation drawn directly via CT) inside a
// UIScrollView so the renderer can be A/B'd against the TK2 path for layout, scroll
// physics, and contentSize parity. Ruby/segment overlays will be wired in subsequent
// passes once the geometry adapter is in place.
// Pure helper: maps a UTF-16 character index to the first segment range that contains it.
// Extracted from the view so it can be unit-tested without a UIView under test.
enum KiokuCoreTextSegmentResolver {
    // Returns the first segment NSRange that contains the given UTF-16 character index,
    // or nil when the index falls outside every segment (whitespace, punctuation gap).
    static func segmentRange(forCharacterIndex characterIndex: Int, in ranges: [NSRange]) -> NSRange? {
        ranges.first { NSLocationInRange(characterIndex, $0) }
    }
}

// Ownership: owned by ReadView (parent). Lifetime tied to the read-mode editorView
// container. Holds value-typed props only; no @State / @ObservedObject.
struct KiokuCoreTextRendererView: UIViewRepresentable {

    let text: String
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    let isFuriganaVisible: Bool
    let isVisualEnhancementsEnabled: Bool
    let isColorAlternationEnabled: Bool
    // Binding so the pinch gesture can write back the user-scaled text size, persisting
    // through the AppStorage-backed `textSize` setting on the read view. Stored as
    // Double to match the @AppStorage type; cast to CGFloat at use sites.
    @Binding var textSize: Double
    let lineSpacing: CGFloat
    let kerning: CGFloat
    // Vertical pixel gap between the kanji line-box top and the ruby's baseline. Drives the
    // user-tunable "furigana gap" slider. The renderer reserves room for ruby above each
    // line via the engine's `topRubyReserve`, and this value controls where inside that
    // reserve the ruby glyphs land.
    let furiganaGap: CGFloat
    // When set, overrides the implicit `textSize * 0.5` furigana font size in both the
    // draw pass and the kern-overhang math, so the user can pick a furigana size
    // independent of the headword size. nil (default) preserves the legacy ratio.
    var furiganaSizeOverride: CGFloat? = nil
    let evenSegmentColor: UIColor
    let oddSegmentColor: UIColor
    let isLineWrappingEnabled: Bool
    let isRubySpacingEnabled: Bool
    // Optional highlight ranges (UTF-16 against `text`). The renderer fills a rounded
    // background under each range. Playback paints on top of selection so a playing tapped
    // segment shows the playback color.
    let selectedHighlightRange: NSRange?
    let playbackHighlightRange: NSRange?
    let selectionHighlightColor: UIColor
    let playbackHighlightColor: UIColor
    // Apple Music-style unplayed-tail dimming: glyphs at UTF-16 locations >= this index
    // fade to `unplayedAlpha`, so the played portion of an active lyric line stays bright
    // while the unplayed tail reads as faded. nil disables the effect (default).
    var unplayedDimmingLocation: Int? = nil
    var unplayedAlpha: CGFloat = 0.18
    // Unknown-segment highlight: locations whose surface isn't in the dictionary. Each gets
    // the unknown color overlaid on its NSRange. Empty = feature off.
    let unknownSegmentLocations: Set<Int>
    let isHighlightUnknownEnabled: Bool
    let unknownSegmentColor: UIColor
    // Pending-LLM-correction highlight: locations the AI re-segmented or re-read, awaiting the
    // user's confirm/reject. Each is tinted green (carrying its furigana) so the change is
    // visible. `changedReadingLocations` is the reading-only subset, threaded for parity with
    // the TextKit path and the typography hash. Empty = no pending correction. Defaulted so the
    // lyrics/song call sites that don't surface LLM changes need not pass them.
    var changedSegmentLocations: Set<Int> = []
    var changedReadingLocations: Set<Int> = []
    // UTF-16 segment start locations for the line the LLM is processing right now.
    // Tinted indigo so the user can see which line is "active" while corrections
    // stream in. Empty when no AI request is in flight or for non-LLM call sites
    // (lyrics, song breakdown) that never surface this state.
    var inFlightSegmentLocations: Set<Int> = []
    // Favorited (saved) word glow: locations whose surface is a saved word get a blurred glow in
    // favoritedGlowColor. Defaulted so the lyrics/song call sites that don't surface it need not pass it.
    var favoritedSegmentLocations: Set<Int> = []
    var isFavoritedGlowEnabled: Bool = false
    var favoritedGlowColor: UIColor = .systemYellow
    // Dev-only debug overlay toggles. The overlay view stays mounted always but only
    // draws when a flag is on, so this is zero-cost for normal users.
    let debugFlags: KiokuDebugOverlayView.Flags
    // Marker for an illegal merge boundary — drawn as a red bar at that segment's
    // bisector when set. Nil = no marker.
    let illegalMergeLocation: Int?
    // Reports tapped segment by NSRange location (UTF-16) and its first-line rect in
    // renderer-local coordinates. `nil` means the tap landed outside any selectable segment
    // and the caller should clear selection.
    // Tap callback. Third argument is the underlying KiokuScrollingTextView so callers can
    // hand it to the sheet-visibility scroll helpers (contentInset.bottom, contentOffset).
    // Passing the scroll view from inside the renderer keeps the SwiftUI struct free of any
    // imperative scroll-view reference plumbing.
    var onSegmentTapped: (Int?, CGRect?, UIScrollView?) -> Void = { _, _, _ in }

    // Long-press callback, same coordinate contract as `onSegmentTapped`. Defaulted to a no-op
    // so existing call sites (the ReadView page) are unaffected and never attach a long-press
    // recognizer. The karaoke card sets this to route long-press → dictionary look-up while a
    // plain tap seeks playback to the word.
    var onSegmentLongPressed: (Int?, CGRect?, UIScrollView?) -> Void = { _, _, _ in }

    // When false, the host scroll view disables user scrolling. Used by the LyricsView
    // active-cue card, which renders the full noteText but pins the viewport to one cue
    // via `playbackHighlightRange`-driven auto-scroll — letting the user scroll would let
    // them drift the card off the active line.
    var isScrollEnabled: Bool = true

    // When false, the renderer is mounted but hidden (ReadView keeps it in the tree behind
    // the editable RichTextEditor so edit↔view toggles are instant). SwiftUI still calls
    // updateUIView on every keystroke while editing, and the typography fingerprint includes
    // the full `text`, so without this gate each character triggers a full CoreText re-typeset
    // of a view nobody can see — the "typing is super laggy" bug. When inactive we skip the
    // rebuild entirely; the view retains its last view-mode content and rebuilds once when edit
    // mode exits (isActive flips true → body re-evaluates → updateUIView runs the build). Default
    // true so the lyrics/song call sites (always visible) need not pass it.
    var isActive: Bool = true

    // Edit↔view scroll sync. `onScrollOffsetYChanged` reports every offset change (including
    // programmatic scrolls) — ReadView routes it into a reference-type memo, NOT @State, so
    // view-mode scrolling doesn't pay a SwiftUI body re-eval per frame (the typography
    // fingerprint hashes the whole note per eval; per-frame evals made long-note scrolling
    // expensive on the legacy renderer). `externalContentOffsetY` is applied exactly ONCE per
    // inactive→active transition — the moment edit mode exits — never on routine updates,
    // so it cannot fight the user's own scrolling. nil defaults keep the lyrics/song call
    // sites out of the sync entirely.
    var externalContentOffsetY: CGFloat? = nil
    var onScrollOffsetYChanged: ((CGFloat) -> Void)? = nil

    // One-shot scroll-to-top trigger. When this value CHANGES between body re-evaluations,
    // the scroll view resets to the top of the content exactly once. Keyed on the active
    // note id so opening a different note starts at the top instead of inheriting the prior
    // note's scroll position. A token (act on the transition) rather than a binding (pin the
    // offset continuously) so it can't fight the user's own scrolling mid-read. Default 0 so
    // the lyrics/song call sites that don't need it need not pass it.
    var scrollToTopToken: Int = 0

    // Horizontal alignment of laid-out lines within the available width. `.natural`/`.left`
    // = engine default (origins at the content inset). `.center` = each line gets a per-
    // line origin shift so it sits centered in the available width; used by LyricsView's
    // active-cue card. Wide-ruby line-start insets are NOT additionally applied under
    // centering — centering already gives the ruby's left tail plenty of room.
    var textAlignment: NSTextAlignment = .natural

    // Where to position the playback-highlighted range vertically within the viewport,
    // as a fraction (0 = top, 0.5 = middle, 1 = bottom). Default 0.32 anchors the active
    // line in the upper third — comfortable for the read tab where users want to see
    // some context below the cursor. The LyricsView active-cue card passes 0.5 so the
    // active cue stays centered in the small clipped viewport; otherwise the next cue's
    // line peeks below the active one.
    var scrollAnchorFraction: CGFloat = 0.32

    // Coordinator holds the textSize captured at the start of a pinch so each .changed
    // delta computes against the original, not the live (already-mutated) value. Also
    // forwards SwiftUI bindings to the UIView's closures.
    final class Coordinator {
        var pinchStartTextSize: Double = 0
    }

    // Required by UIViewRepresentable when a Coordinator is needed; we use it to hold
    // pinch-gesture state that has to survive between .began and .changed events.
    func makeCoordinator() -> Coordinator { Coordinator() }

    // Builds the scroll-view host + content view once. Tap forwarding closure is installed
    // here because it captures the view reference for the cached segment lookup.
    func makeUIView(context: Context) -> KiokuScrollingTextView {
        let view = KiokuScrollingTextView()
        view.alwaysBounceVertical = isScrollEnabled
        view.isScrollEnabled = isScrollEnabled
        // Tap callback wiring lives in `updateUIView` (not here) so each SwiftUI body
        // re-evaluation captures the freshest `onSegmentTapped` closure — without that
        // re-wire, the closure would lock in the FIRST struct instance's view of state
        // (e.g. `dictionaryStore = nil` before `readResources` finishes loading) and
        // every tap thereafter would route through the stale snapshot.
        // Pinch → text-size binding. The coordinator captures the starting size on
        // .began so each .changed multiplies a stable base by the cumulative scale.
        let coordinator = context.coordinator
        view.onPinchBegan = { coordinator.pinchStartTextSize = textSize }
        view.onPinchChanged = { scale in
            let target = coordinator.pinchStartTextSize * Double(scale)
            let clamped = min(
                max(target, TypographySettings.textSizeRange.lowerBound),
                TypographySettings.textSizeRange.upperBound
            )
            textSize = clamped
        }
        return view
    }

    // Rebuilds the attributed string, applies layout (with per-line origin shifts for
    // wide-ruby line-starts), feeds the debug overlay, and emits inset / segment-gap
    // measurement logs when the inset-guide debug flag is on.
    func updateUIView(_ uiView: KiokuScrollingTextView, context: Context) {
        // Inactive→active edge detection MUST happen before the isActive guard — the guard
        // returns while hidden, so it can never record "I was inactive" itself. The edge is
        // when edit mode just exited; that's the one moment the external scroll offset (the
        // editor's last position) should be applied. See `externalContentOffsetY`.
        let becameActive = isActive && uiView.wasActiveInLastUpdate == false
        uiView.wasActiveInLastUpdate = isActive

        // Hidden behind the editable RichTextEditor (edit mode): skip all work. Every keystroke
        // re-evaluates ReadView.body and would otherwise re-typeset the entire note here for a
        // view nobody can see. The view keeps its last view-mode content and rebuilds once when
        // editing ends (isActive flips back to true). See the `isActive` property comment.
        guard isActive else { return }

        // Re-wire per body re-evaluation (same staleness rationale as the tap callback below).
        uiView.onScrollOffsetYChanged = onScrollOffsetYChanged

        // Re-apply scroll enablement on every update so the LyricsView toggle is honored
        // when the host re-evaluates with a different value (e.g. dismiss vs. active).
        uiView.isScrollEnabled = isScrollEnabled
        uiView.alwaysBounceVertical = isScrollEnabled

        // Re-wire the tap callback on every body re-evaluation. The closure captures the
        // CURRENT SwiftUI struct's `onSegmentTapped`, so callers see the latest state
        // (text, segmentRanges, dictionaryStore, etc.). Wiring this once in makeUIView
        // would lock in the first struct instance's snapshot — a real footgun because
        // SwiftUI structs are recreated on every re-render but the closure they captured
        // is not.
        uiView.onCharacterTapped = { [weak uiView, onSegmentTapped] characterIndex in
            guard let uiView else { return }
            TapDiagnostics.mark("onCharacterTapped entered")
            guard let characterIndex else {
                onSegmentTapped(nil, nil, uiView)
                return
            }
            guard let match = KiokuCoreTextSegmentResolver.segmentRange(
                forCharacterIndex: characterIndex,
                in: uiView.cachedSegmentNSRanges
            ) else {
                onSegmentTapped(nil, nil, uiView)
                return
            }
            let rect = uiView.contentView.layoutEngine.firstRect(forCharacterRange: match)
                .map { uiView.convertContentRectToHost($0) }
            TapDiagnostics.mark("segment resolved (loc=\(match.location), len=\(match.length))")
            onSegmentTapped(match.location, rect, uiView)
            TapDiagnostics.mark("onSegmentTapped returned (back in KiokuCoreTextRendererView wiring)")
        }

        // Mirror the tap wiring for long-press. Only attaches a recognizer when the host set a
        // non-default `onSegmentLongPressed` (the karaoke card does; the page does not), so the
        // plain ReadView page keeps a single tap recognizer and unchanged behaviour.
        uiView.onCharacterLongPressed = { [weak uiView, onSegmentLongPressed] characterIndex in
            guard let uiView else { return }
            guard let characterIndex else {
                onSegmentLongPressed(nil, nil, uiView)
                return
            }
            guard let match = KiokuCoreTextSegmentResolver.segmentRange(
                forCharacterIndex: characterIndex,
                in: uiView.cachedSegmentNSRanges
            ) else {
                onSegmentLongPressed(nil, nil, uiView)
                return
            }
            let rect = uiView.contentView.layoutEngine.firstRect(forCharacterRange: match)
                .map { uiView.convertContentRectToHost($0) }
            onSegmentLongPressed(match.location, rect, uiView)
        }
        let font = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: furiganaSizeOverride ?? (textSize * 0.5))

        // Fingerprint the typography-affecting inputs. Selection state and highlight bands
        // are NOT part of the build (they're drawn as overlays), so changing only those
        // doesn't require re-typesetting the note. On long notes this avoids ~tens of ms
        // of CT relayout work per tap.
        var typographyHasher = Hasher()
        typographyHasher.combine(text)
        for range in segmentationRanges {
            typographyHasher.combine(range.lowerBound.utf16Offset(in: text))
            typographyHasher.combine(range.upperBound.utf16Offset(in: text))
        }
        for (key, value) in furiganaBySegmentLocation {
            typographyHasher.combine(key)
            typographyHasher.combine(value)
        }
        for (key, value) in furiganaLengthBySegmentLocation {
            typographyHasher.combine(key)
            typographyHasher.combine(value)
        }
        typographyHasher.combine(textSize)
        typographyHasher.combine(lineSpacing)
        typographyHasher.combine(kerning)
        typographyHasher.combine(isVisualEnhancementsEnabled)
        typographyHasher.combine(isColorAlternationEnabled)
        typographyHasher.combine(isFuriganaVisible)
        typographyHasher.combine(isLineWrappingEnabled)
        typographyHasher.combine(isRubySpacingEnabled)
        typographyHasher.combine(evenSegmentColor.description)
        typographyHasher.combine(oddSegmentColor.description)
        for location in unknownSegmentLocations { typographyHasher.combine(location) }
        typographyHasher.combine(isHighlightUnknownEnabled)
        typographyHasher.combine(unknownSegmentColor.description)
        for location in changedSegmentLocations.sorted() { typographyHasher.combine(location) }
        for location in changedReadingLocations.sorted() { typographyHasher.combine(location) }
        for location in inFlightSegmentLocations.sorted() { typographyHasher.combine(location) }
        for location in favoritedSegmentLocations.sorted() { typographyHasher.combine(location) }
        typographyHasher.combine(isFavoritedGlowEnabled)
        typographyHasher.combine(favoritedGlowColor.description)
        typographyHasher.combine(unplayedDimmingLocation ?? -1)
        typographyHasher.combine(unplayedAlpha)
        typographyHasher.combine(furiganaGap)
        typographyHasher.combine(furiganaSizeOverride ?? -1)
        let typographyFingerprint = typographyHasher.finalize()

        if uiView.lastTypographyFingerprint != typographyFingerprint {
            let output = KiokuCoreTextAttributedStringBuilder.build(
                .init(
                    text: text,
                    segmentationRanges: segmentationRanges,
                    furiganaBySegmentLocation: furiganaBySegmentLocation,
                    furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
                    textSize: textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    isVisualEnhancementsEnabled: isVisualEnhancementsEnabled,
                    isColorAlternationEnabled: isColorAlternationEnabled,
                    isFuriganaVisible: isFuriganaVisible,
                    isLineWrappingEnabled: isLineWrappingEnabled,
                    isRubySpacingEnabled: isRubySpacingEnabled,
                    evenSegmentColor: evenSegmentColor,
                    oddSegmentColor: oddSegmentColor,
                    unknownSegmentLocations: unknownSegmentLocations,
                    isHighlightUnknownEnabled: isHighlightUnknownEnabled,
                    unknownSegmentColor: unknownSegmentColor,
                    changedSegmentLocations: changedSegmentLocations,
                    changedReadingLocations: changedReadingLocations,
                    inFlightSegmentLocations: inFlightSegmentLocations,
                    favoritedSegmentLocations: favoritedSegmentLocations,
                    isFavoritedGlowEnabled: isFavoritedGlowEnabled,
                    favoritedGlowColor: favoritedGlowColor,
                    isSegmentPacked: isRubySpacingEnabled && isFuriganaVisible,
                    unplayedDimmingLocation: unplayedDimmingLocation,
                    unplayedAlpha: unplayedAlpha,
                    furiganaSizeOverride: furiganaSizeOverride
                )
            )
            uiView.contentView.setAttributedString(output.attributedString)
            uiView.contentView.rubyEntries = isFuriganaVisible ? output.rubyEntries : []
            uiView.lastTypographyFingerprint = typographyFingerprint
        }

        // baseTextSize / furiganaGap are cheap stored-property writes; they don't trigger
        // a re-typeset on their own but downstream draw passes read them. Always set them
        // so the renderer stays in sync even on the cached-typography path.
        uiView.contentView.baseTextSize = CGFloat(textSize)
        uiView.contentView.furiganaFontSizeOverride = furiganaSizeOverride
        uiView.contentView.furiganaGap = isFuriganaVisible ? furiganaGap : 0
        uiView.contentView.isFavoritedGlowEnabled = isFavoritedGlowEnabled
        // Geometry is resolved by the SHARED RenderGeometry helper so this path produces
        // the same line origins as RichTextEditor — toggling edit↔view never moves a
        // character. The reserve for ruby is baked into the top inset (line 0) and the
        // inter-line gap (line 1+); we no longer apply a per-line ruby reserve in the
        // engine because it would be additive on top of the geometry-supplied gap and
        // recreate the divergence we just removed.
        let geometry = RenderGeometry.resolve(
            textSize: textSize,
            userLineSpacing: lineSpacing,
            furiganaGap: furiganaGap,
            furiganaSizeOverride: furiganaSizeOverride
        )
        uiView.contentView.setTopRubyReserve(0)
        uiView.contentView.setLineSpacing(geometry.interLineGap)
        // Same geometry as RichTextEditor so character positions match across edit↔view.
        uiView.contentView.setContentInset(geometry.contentInset)
        uiView.cachedSegmentNSRanges = segmentationRanges
            .map { NSRange($0, in: text) }
            .filter { $0.location != NSNotFound && $0.length > 0 }
        // Hand the same ranges to the engine so it can forbid mid-segment line breaks.
        // TK2's `shouldBreakLineBefore:hyphenating:` delegate did this implicitly; the CT
        // path post-processes CT's break suggestion against this list instead. Without
        // this, a long compound (抜け殻, 思い出) at the right margin would be bisected
        // mid-character; with it, the whole compound wraps to the next line as a unit.
        uiView.contentView.setSegmentNSRanges(uiView.cachedSegmentNSRanges)
        // The packer doesn't read paragraph attributes, so mirror the wrap flag onto the
        // engine BEFORE invoking setSegmentPacking — the packer reads this flag while it
        // rebuilds the packed layout, and `isLineWrappingEnabled` is a plain stored
        // property with no relayout trigger. Setting it after the rebuild meant the first
        // packed layout used the previous/default `true` value and LyricsView's
        // single-line active-cue card could wrap long cue segments until some unrelated
        // update happened to trigger another rebuild.
        uiView.contentView.layoutEngine.isLineWrappingEnabled = isLineWrappingEnabled
        // Toggle segment-packed layout based on the ruby-spacing user setting. When on,
        // the engine packs segments by max(headword, ruby) footprint with zero inter-
        // segment gap and atomic seg+ruby wrapping. When off, the engine uses CT's
        // word-wrap and the renderer's existing per-line draw path (no behavior change).
        uiView.contentView.layoutEngine.setSegmentPacking(
            enabled: isRubySpacingEnabled && isFuriganaVisible,
            furiganaByLocation: isFuriganaVisible ? furiganaBySegmentLocation : [:],
            furiganaLengthByLocation: isFuriganaVisible ? furiganaLengthBySegmentLocation : [:],
            bodyFont: font,
            furiganaFont: furiganaFont
        )

        // Apply per-line origin shifts for wide-ruby line-starts. Replacement for TextKit
        // 2's textContainer.exclusionPaths. CTLineGetImageBounds doesn't include ruby
        // annotation extents (CT keeps ruby within the base run's advance with
        // overhang=.auto), so we compute the shift from the measured ruby vs. kanji
        // widths directly — same approach as TK2's exclusion-path width calculation.
        // Both shift sources are gated on isRubySpacingEnabled — when the user has Ruby
        // Spacing off, line origins stay flush at the inset, and ruby annotations are
        // allowed to overhang past the inset guide (matching TK2's behavior with the
        // same toggle off).
        // Mirror the requested alignment onto the UIView so `layoutSubviews` can re-run
        // the centering math after bounds are known. Without this, the first updateUIView
        // pass runs with bounds.width=0 and the lyrics card sits flush-left until some
        // unrelated state change re-triggers updateUIView at a moment with valid bounds.
        uiView.textAlignment = textAlignment
        var shifts: [Int: CGFloat] = [:]
        // Centering takes precedence over wide-ruby line-start insets — when text is centered
        // there's already room on the left for ruby overhang. The shifts dict is the union of
        // (centering | wide-ruby), with whichever the active mode dictates winning.
        if textAlignment == .center {
            // Centering is computed identically here and in `layoutSubviews`; the helper
            // returns the dict so we can fold it into `shifts` and hand the merged map to
            // `setLineOriginShifts` exactly once per update. The layout-time path bypasses
            // updateUIView entirely and calls `applyCenteringShiftsIfNeeded` directly.
            shifts = uiView.computeCenteringShifts()
        }
        // Wide-ruby / envelope-vs-inset shifts were intentionally removed here. The previous
        // logic pushed any line whose leading kanji had wider-than-kanji ruby to the right by
        // the ruby's left overhang. Visually that created a gap between the kanji and the
        // inset guide for every furigana-bearing line, while pure-kana lines (no overhang)
        // continued to sit flush — an inconsistent and incorrect look. Standard Japanese
        // typography sits the kanji at the inset and lets the ruby overhang into the margin
        // (the debug inset-guide line is a visual aid; it does not bound the ruby annotation).
        // Centering shifts above are unaffected.
        uiView.contentView.setLineOriginShifts(shifts)

        // Emit gap measurements to the unified log so the live app proves alignment
        // numerically — inset → first-segment-left per line, and segment-right → next-
        // segment-left per same-line pair. Toggled by the same flag as the visual
        // inset guide so it doesn't spam logs in normal use.
        // Dump segment-by-segment envelope heights so we can verify the standardization
        // is actually taking effect. Gated by envelopeRects toggle.
        if debugFlags.envelopeRects && isRubySpacingEnabled {
            for seg in uiView.debugOverlay.segmentGeometry.prefix(8) {
                NSLog("[kioku.ct.geom] loc=%d envelope=(%.1f,%.1f,%.1f,%.1f) headword.h=%.1f furi.h=%.1f",
                      seg.location,
                      Double(seg.envelopeRect.origin.x), Double(seg.envelopeRect.origin.y),
                      Double(seg.envelopeRect.width), Double(seg.envelopeRect.height),
                      Double(seg.headwordRect.height),
                      Double(seg.furiganaRect?.height ?? 0))
            }
        }
        // Mirror TK2's `[envelope-gap]` log so we can compare gaps side-by-side. Gated
        // by the same debug toggle TK2 uses (envelopeRects), so the two emit in lockstep.
        // Also gated on isRubySpacingEnabled — these logs only make sense when the
        // spacing pipeline is actually active.
        if debugFlags.envelopeRects && isRubySpacingEnabled {
            let nsText = text as NSString
            let ranges = uiView.cachedSegmentNSRanges
            for i in 0..<max(0, ranges.count - 1) {
                let a = ranges[i]
                let b = ranges[i + 1]
                guard let rectA = uiView.contentView.layoutEngine.firstRect(forCharacterRange: a),
                      let rectB = uiView.contentView.layoutEngine.firstRect(forCharacterRange: b) else { continue }
                guard abs(rectA.midY - rectB.midY) < 1.0 else { continue }
                let gap = rectB.minX - rectA.maxX
                guard abs(gap) >= 0.05 else { continue }
                NSLog("[kioku.ct envelope-gap] %@ → %@ gap=%.1fpt", nsText.substring(with: a), nsText.substring(with: b), Double(gap))
            }
        }
        if debugFlags.leftInsetGuide && isRubySpacingEnabled {
            let inset = uiView.contentView.layoutEngine.contentInset.left
            for (lineIndex, line) in uiView.contentView.layoutEngine.lines.enumerated() {
                guard let firstSeg = uiView.cachedSegmentNSRanges.first(where: { $0.location == line.stringRange.location }),
                      let rect = uiView.contentView.layoutEngine.firstRect(forCharacterRange: firstSeg)
                else { continue }
                let gap = rect.minX - inset
                NSLog("[kioku.ct.gap] line=\(lineIndex) inset=\(inset) firstSegLeft=\(rect.minX) gap=\(String(format: "%.2f", gap)) shift=\(shifts[lineIndex] ?? 0)")
            }
            // Inter-segment gaps, same-line pairs only. We measure from segment-A's
            // GLYPH right edge (excluding the trailing .kern we injected) to segment-B's
            // left edge. firstRect.maxX would include the kern advance and falsely
            // report gap=0, since adjacent segments share an edge in CTLine coords.
            let ranges = uiView.cachedSegmentNSRanges
            let nsText = text as NSString
            for i in 0..<max(0, ranges.count - 1) {
                let a = ranges[i]
                let b = ranges[i + 1]
                guard let rectA = uiView.contentView.layoutEngine.firstRect(forCharacterRange: a),
                      let rectB = uiView.contentView.layoutEngine.firstRect(forCharacterRange: b)
                else { continue }
                guard abs(rectA.midY - rectB.midY) < 5 else { continue }
                let surfaceA = nsText.substring(with: a)
                let glyphWidthA = ceil((surfaceA as NSString).size(withAttributes: [.font: font]).width)
                let glyphRightA = rectA.minX + glyphWidthA
                let gap = rectB.minX - glyphRightA
                NSLog("[kioku.ct.gap] pair locA=\(a.location) locB=\(b.location) surfaceA=\"\(surfaceA)\" glyphRightA=\(String(format: "%.2f", glyphRightA)) leftB=\(String(format: "%.2f", rectB.minX)) gap=\(String(format: "%.2f", gap))")
            }
        }

        // Build the lexical segment list and hand it to the scroll view. Non-lexical
        // segments (whitespace, newlines, pure punctuation) are dropped — they exist
        // in cachedSegmentNSRanges because the concat-equals-content invariant requires
        // every character to belong to a segment, but they have no headword or ruby and
        // would otherwise render as empty envelopes. The scroll view's
        // `recomputeDebugGeometry` runs both now AND on layoutSubviews, so a view that
        // first laid out with width=0 (preview) still gets accurate geometry once the
        // real width arrives.
        let nsText = text as NSString
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let lexicalSegmentNSRanges: [NSRange] = uiView.cachedSegmentNSRanges.filter { range in
            let surface = nsText.substring(with: range)
            return SegmentClassifier.isNonLexical(surface) == false
        }
        uiView.debugGeometryInputs = KiokuScrollingTextView.DebugGeometryInputs(
            lexicalSegmentNSRanges: lexicalSegmentNSRanges,
            furiganaByLocation: furiganaBySegmentLocation,
            furiganaLengthByLocation: furiganaLengthBySegmentLocation,
            baseFont: baseFont,
            furiganaFont: furiganaFont,
            isFuriganaVisible: isFuriganaVisible
        )
        uiView.debugOverlay.illegalMergeLocation = illegalMergeLocation
        uiView.debugOverlay.flags = debugFlags

        // Selection sits below playback so a playing-tapped segment shows the playback color.
        var bands: [KiokuCoreTextView.HighlightBand] = []
        if let range = selectedHighlightRange, range.length > 0 {
            bands.append(.init(range: range, color: selectionHighlightColor))
        }
        if let range = playbackHighlightRange, range.length > 0 {
            bands.append(.init(range: range, color: playbackHighlightColor))
        }
        uiView.contentView.highlightBands = bands

        // Restore the editor's scroll position when edit mode just exited. Edge-triggered only:
        // applying on routine updates would snap the view back to a stale offset on every body
        // re-eval while the user scrolls (the shared offset is NOT updated per frame in view
        // mode — see `externalContentOffsetY`). The toggle case leaves content unchanged, so
        // contentSize is valid for clamping here.
        if becameActive, let externalContentOffsetY {
            uiView.applyExternalScrollOffsetY(externalContentOffsetY)
        }

        // Reset to the top of the content when the active note changed (token transition).
        // Runs before the playback auto-scroll below so a genuinely-active cue can still win
        // the rare case where both fire in the same pass; on a normal note open the playback
        // range is nil and the top reset stands.
        uiView.scrollToTopIfTokenChanged(scrollToTopToken)

        // Auto-scroll the playback range into view so the active cue stays visible during
        // audio playback. The anchor fraction is configurable so LyricsView can center
        // the active cue in its small viewport without bleeding the next cue's line.
        if let range = playbackHighlightRange, range.length > 0 {
            uiView.scrollRangeIntoView(range, anchorFraction: scrollAnchorFraction)
        }

        uiView.setNeedsLayout()
    }

    // Tells SwiftUI what size this representable wants. ONLY the non-scrolling case is
    // sized to content here — that's the SettingsPreviewRenderer pattern, where the host
    // (a Form Section row) doesn't constrain height and a bare UIScrollView would
    // collapse to ~0 height ("just a little red dot").
    //
    // For the scrollable case (ReadView), we return nil so SwiftUI uses the parent's
    // proposed size — i.e., the safe-area-bounded read tab area. Reporting the full
    // content height there would cause the parent container to expand to that height,
    // pushing the nav bar and tab bar offscreen (which is the bug this method created
    // when it returned content height unconditionally).
    //
    // LyricsView's call site sets isScrollEnabled: false but also pins an explicit
    // .frame(height:) above this view — that explicit frame wins regardless of what we
    // return here, so the centering card behaves the same in either branch.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KiokuScrollingTextView, context: Context) -> CGSize? {
        guard isScrollEnabled == false else { return nil }
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let height = uiView.contentView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }
}
