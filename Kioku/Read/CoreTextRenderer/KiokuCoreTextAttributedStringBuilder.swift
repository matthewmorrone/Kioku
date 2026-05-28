import UIKit
import CoreText

// Builds the NSAttributedString consumed by KiokuCoreTextView along with the list of ruby
// entries to draw above it. The renderer used to bake CTRubyAnnotation into the attributed
// string, which let CoreText position ruby for us but gave away vertical-gap control — Apple
// gives no public knob to set the kanji-to-ruby gap on a CTRubyAnnotation. The TK2-style
// `furiganaGap` slider went silently dead as a result.
//
// We now emit ruby as DATA (RubyEntry list) and the view draws each reading itself in its
// draw pass, using the layout engine's `firstRect(forCharacterRange:)` for kanji-run rects.
// This matches the architecture sketched in docs/custom-renderer-plan.md ("existing overlay
// code draws ruby ... at coordinates from CTLine offsets") and restores per-pixel control of
// the kanji↔ruby gap. The vertical room reserved for ruby above each line is set on the
// engine via `topRubyReserve`.
//
// Inputs mirror the subset of ReadTextStyleResolver inputs that affect either the base
// glyphs or the ruby entries. Selection envelopes, debug overlays, and playback highlights
// stay on the overlay layer.
enum KiokuCoreTextAttributedStringBuilder {

    // A single furigana run: location/length in UTF-16 against the source `text`, and the
    // reading string to draw centered above that run. Emitted by `build` and consumed by the
    // view's draw pass — the layout engine resolves each entry's screen rect at draw time, so
    // entries survive reflow on text-size / width changes without needing recomputation here.
    struct RubyEntry: Equatable {
        let location: Int
        let length: Int
        let reading: String
    }

    // Output bundle: the base attributed string (no CTRubyAnnotation) plus the ruby entries.
    struct Output {
        let attributedString: NSAttributedString
        let rubyEntries: [RubyEntry]
    }

    struct Inputs {
        let text: String
        let segmentationRanges: [Range<String.Index>]
        // Keyed by kanji-run UTF-16 location (not segment location). Each entry covers
        // a specific kanji run inside (or equal to) a segment. The matching length is in
        // furiganaLengthBySegmentLocation. A single segment can contribute multiple
        // entries when it has more than one kanji run.
        let furiganaBySegmentLocation: [Int: String]
        let furiganaLengthBySegmentLocation: [Int: Int]
        let textSize: CGFloat
        let lineSpacing: CGFloat
        let kerning: CGFloat
        let isVisualEnhancementsEnabled: Bool
        let isColorAlternationEnabled: Bool
        let isFuriganaVisible: Bool
        var isLineWrappingEnabled: Bool = true
        // Adds extra kerning at the trailing edge of any segment whose ruby is wider than
        // its base glyphs, so the next segment doesn't visually crowd into the ruby
        // overhang. This is the CoreText analogue of TK2's pair-wise spacing correction.
        var isRubySpacingEnabled: Bool = true
        let evenSegmentColor: UIColor
        let oddSegmentColor: UIColor
        // Unknown-segment highlighting. When `isHighlightUnknownEnabled` is true, any
        // segment whose location appears in `unknownSegmentLocations` is colored with
        // `unknownSegmentColor` instead of the alternation palette.
        var unknownSegmentLocations: Set<Int> = []
        var isHighlightUnknownEnabled: Bool = false
        var unknownSegmentColor: UIColor = .label
        // When true, the renderer is in segment-packed mode and handles inter-segment
        // spacing via per-segment X placement. The builder must NOT inject its
        // ruby-overhang kerning compensation in that case — the kern bump would inflate
        // each headword's measured CTLine advance, the packer would read that inflated
        // value as the headword width, and footprint centering would put the headword
        // off-center inside its footprint. Default false to preserve classic behavior.
        var isSegmentPacked: Bool = false
        // Apple Music-style "unplayed tail" dimming. When set, foreground colors at
        // UTF-16 locations >= this index get their alpha multiplied by `unplayedAlpha`
        // so the unplayed portion of an active lyric line reads as faded white while
        // the played portion stays full-strength. nil disables the effect.
        var unplayedDimmingLocation: Int? = nil
        var unplayedAlpha: CGFloat = 0.18
        // When set, replaces the implicit `textSize * 0.5` furigana font size used for
        // the ruby-overhang kern math. Default nil preserves legacy behavior.
        var furiganaSizeOverride: CGFloat? = nil
    }

    // Composes the renderer-ready NSAttributedString: base font + paragraph style,
    // per-segment foreground color (with unknown-segment override), and inter-segment kern
    // compensation for ruby overhang. Ruby itself is returned as data — the view draws each
    // entry manually so the kanji↔ruby gap is tunable (see file header for the rationale).
    static func build(_ inputs: Inputs) -> Output {
        let baseFont = UIFont.systemFont(ofSize: inputs.textSize)
        let paragraph = NSMutableParagraphStyle()
        // Don't set paragraph.lineSpacing here: with CoreText, CTRubyAnnotation already
        // inflates each line's ascent to reserve the ruby row, and the engine adds the
        // user-configured extra spacing in setLineSpacing. Adding it here too would
        // compound the gap and visibly drift from the TK2 baseline.
        paragraph.lineBreakMode = inputs.isLineWrappingEnabled ? .byWordWrapping : .byClipping

        let result = NSMutableAttributedString(
            string: inputs.text,
            attributes: [
                .font: baseFont,
                .kern: inputs.kerning,
                .paragraphStyle: paragraph,
                .foregroundColor: UIColor.label,
            ]
        )

        guard inputs.isVisualEnhancementsEnabled else {
            return Output(attributedString: result, rubyEntries: [])
        }

        let nsTextForSegments = result.string as NSString
        var alternationIndex = 0
        for segmentRange in inputs.segmentationRanges {
            let nsRange = NSRange(segmentRange, in: inputs.text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }

            // Skip pure-punctuation / pure-whitespace segments so they don't pick up alternation
            // colors. Uses the shared classifier so the TK2 and CT paths agree on which
            // segments count as "stylable."
            let segmentText = nsTextForSegments.substring(with: nsRange)
            if SegmentClassifier.isNonLexical(segmentText) { continue }

            // Unknown highlight takes precedence over alternation (matches TK2 behavior).
            if inputs.isHighlightUnknownEnabled && inputs.unknownSegmentLocations.contains(nsRange.location) {
                result.addAttribute(.foregroundColor, value: inputs.unknownSegmentColor, range: nsRange)
            } else if inputs.isColorAlternationEnabled {
                let color = alternationIndex.isMultiple(of: 2)
                    ? inputs.evenSegmentColor
                    : inputs.oddSegmentColor
                result.addAttribute(.foregroundColor, value: color, range: nsRange)
            }
            alternationIndex += 1

        }

        if let dimFrom = inputs.unplayedDimmingLocation, dimFrom < result.length {
            let dimRange = NSRange(location: dimFrom, length: result.length - dimFrom)
            let alpha = inputs.unplayedAlpha
            result.enumerateAttribute(.foregroundColor, in: dimRange, options: []) { value, subrange, _ in
                let base = (value as? UIColor) ?? .label
                result.addAttribute(.foregroundColor, value: base.withAlphaComponent(alpha), range: subrange)
            }
        }

        // Ruby application. The furiganaBySegmentLocation dictionary is keyed by each
        // KANJI RUN'S UTF-16 location (often inside a segment, not at the segment start),
        // so iterate the dict directly and emit one RubyEntry per run. The view's draw pass
        // consumes these and positions each reading using the layout engine's kanji rect.
        var rubyEntries: [RubyEntry] = []
        if inputs.isVisualEnhancementsEnabled, inputs.isFuriganaVisible {
            let furiganaFont = UIFont.systemFont(ofSize: inputs.furiganaSizeOverride ?? (inputs.textSize * 0.5))
            // Cache segment NSRanges so spacing compensation can route the trailing .kern
            // to the segment's LAST character rather than the kanji's — keeps okurigana
            // tucked against its kanji and pushes the gap to the segment boundary, where
            // it belongs visually.
            let segmentNSRanges: [NSRange] = inputs.segmentationRanges
                .map { NSRange($0, in: inputs.text) }
                .filter { $0.location != NSNotFound && $0.length > 0 }
            for (kanjiLoc, reading) in inputs.furiganaBySegmentLocation {
                guard reading.isEmpty == false,
                      let kanjiLen = inputs.furiganaLengthBySegmentLocation[kanjiLoc],
                      kanjiLen > 0,
                      kanjiLoc + kanjiLen <= result.length else { continue }
                let kanjiRange = NSRange(location: kanjiLoc, length: kanjiLen)
                let kanjiText = (result.string as NSString).substring(with: kanjiRange)
                // Skip when the reading is identical to the surface (no annotation needed).
                if reading == kanjiText { continue }
                rubyEntries.append(RubyEntry(
                    location: kanjiLoc,
                    length: kanjiLen,
                    reading: reading
                ))

                // Inter-segment spacing: when ruby is wider than its kanji, BOTH sides
                // overhang the kanji. Push gap into the adjacent segment boundaries so
                // okurigana stays glued to its kanji:
                //   - right overhang → kern on the LAST CHARACTER of the CONTAINING segment
                //   - left  overhang → kern on the LAST CHARACTER of the PRIOR segment
                //     (visible only when the kanji sits at the start of its segment, so the
                //     ruby's left tail actually crosses the segment boundary)
                //
                // SKIPPED in segment-packed mode: the packer handles inter-segment spacing
                // via per-segment footprint placement, so adding kern here would inflate
                // the measured CTLine advance and break the packer's footprint math.
                if inputs.isRubySpacingEnabled && inputs.isSegmentPacked == false {
                    let kanjiW = ceil((kanjiText as NSString).size(withAttributes: [.font: baseFont]).width)
                    let rubyW = ceil((reading as NSString).size(withAttributes: [.font: furiganaFont]).width)
                    let overhang = max(0, ceil((rubyW - kanjiW) / 2))
                    if overhang > 0.5, let containingIdx = segmentNSRanges.firstIndex(where: { NSLocationInRange(kanjiLoc, $0) }) {
                        let containing = segmentNSRanges[containingIdx]
                        // Right side: bump .kern at the containing segment's tail ONLY
                        // when there's a meaningful next segment to push away from. When
                        // the only thing after this segment is line-end punctuation or a
                        // newline, the kern would create a hanging gap with nothing on
                        // the other side. Detect by checking whether any non-punctuation
                        // segment follows on the same line (= before the next newline).
                        let nsText = result.string as NSString
                        let tailIdx = containing.location + containing.length - 1
                        let afterLocation = tailIdx + 1
                        let lineEnd: Int = {
                            for offset in afterLocation..<nsText.length {
                                if nsText.character(at: offset) == 0x0A { return offset }
                            }
                            return nsText.length
                        }()
                        let hasMeaningfulFollower = segmentNSRanges.contains { other in
                            other.location > containing.location
                                && other.location < lineEnd
                                && other.length > 0
                        }
                        if hasMeaningfulFollower {
                            let tailRange = NSRange(location: tailIdx, length: 1)
                            let tailKern = (result.attribute(.kern, at: tailIdx, effectiveRange: nil) as? CGFloat) ?? inputs.kerning
                            result.addAttribute(.kern, value: tailKern + overhang, range: tailRange)
                        }

                        // Left side: when this kanji starts the containing segment, the
                        // ruby's left half sits past the segment boundary. Push the prior
                        // segment's tail away to make room — but only when the prior
                        // segment is on the SAME line (no newline between them).
                        if kanjiLoc == containing.location, containingIdx > 0 {
                            let prior = segmentNSRanges[containingIdx - 1]
                            let priorEnd = prior.location + prior.length
                            // Skip if there's a newline between prior and this segment.
                            var crossesNewline = false
                            for offset in priorEnd..<containing.location {
                                if nsText.character(at: offset) == 0x0A {
                                    crossesNewline = true; break
                                }
                            }
                            if crossesNewline == false {
                                let priorTailIdx = prior.location + prior.length - 1
                                let priorTailRange = NSRange(location: priorTailIdx, length: 1)
                                let priorKern = (result.attribute(.kern, at: priorTailIdx, effectiveRange: nil) as? CGFloat) ?? inputs.kerning
                                result.addAttribute(.kern, value: priorKern + overhang, range: priorTailRange)
                            }
                        }
                    }
                }
            }
        }

        return Output(attributedString: result, rubyEntries: rubyEntries)
    }

    // Returns ceil((rubyWidth - kanjiWidth)/2) when the LAST kanji run in the segment
    // sits at the segment's right edge AND its ruby is wider than the kanji. The next
    // segment will visually crowd into the overhang otherwise; bumping the trailing
    // .kern by this amount restores the gap.
    private static func rightSideRubyOverhang(
        segmentSurface: String,
        reading: String,
        baseFont: UIFont,
        furiganaFont: UIFont
    ) -> CGFloat {
        let runs = FuriganaAttributedString.kanjiRuns(in: segmentSurface)
        guard let lastRun = runs.last,
              let runReadings = FuriganaAttributedString.normalizedRunReadings(
                  surface: segmentSurface, reading: reading, runs: runs
              ), runReadings.count == runs.count else { return 0 }
        let lastReading = runReadings[runs.count - 1]
        guard lastReading.isEmpty == false else { return 0 }
        let characters = Array(segmentSurface)
        // Trailing okurigana would absorb the overhang visually, so only compensate when
        // the kanji is at the segment's right edge.
        guard lastRun.end == characters.count else { return 0 }
        let kanji = String(characters[lastRun.start..<lastRun.end])
        let kanjiW = ceil((kanji as NSString).size(withAttributes: [.font: baseFont]).width)
        let rubyW = ceil((lastReading as NSString).size(withAttributes: [.font: furiganaFont]).width)
        return max(0, ceil((rubyW - kanjiW) / 2))
    }

    // Tags each contiguous kanji run within the segment with a CTRubyAnnotation whose
    // text is the projection of the reading onto that run. Falls back to a single
    // segment-wide annotation when run-projection fails (matches FuriganaAttributedString).
    private static func applyRuby(
        to attributed: NSMutableAttributedString,
        segmentNSRange: NSRange,
        reading: String
    ) {
        let nsString = attributed.string as NSString
        let segmentSurface = nsString.substring(with: segmentNSRange)
        let runs = FuriganaAttributedString.kanjiRuns(in: segmentSurface)
        guard runs.isEmpty == false else { return }

        // Convert character-offset runs (Swift Character indices) into UTF-16 NSRanges
        // anchored at the segment's NSRange.location.
        let characters = Array(segmentSurface)

        // When the reading projects cleanly per-run, prefer the per-run annotation so
        // okurigana never sits inside ruby.
        if let runReadings = FuriganaAttributedString.normalizedRunReadings(
            surface: segmentSurface,
            reading: reading,
            runs: runs
        ), runReadings.count == runs.count {
            for (i, run) in runs.enumerated() {
                let runReading = runReadings[i]
                guard runReading.isEmpty == false else { continue }
                let kanjiText = String(characters[run.start..<run.end])
                if runReading == kanjiText { continue }
                let runNSRange = nsRange(in: segmentSurface,
                                         startChar: run.start,
                                         endChar: run.end,
                                         offsetByUTF16: segmentNSRange.location)
                let annotation = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before,
                    runReading as CFString,
                    [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary
                )
                attributed.addAttribute(
                    NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                    value: annotation,
                    range: runNSRange
                )
            }
        } else {
            // Whole-segment fallback. Matches what FuriganaAttributedString does when run
            // projection fails — better to show no ruby than to drop okurigana inside it.
            // Skipped intentionally to mirror that behavior.
        }
    }

    // Maps a [startChar, endChar) range over `surface`'s Character array into an NSRange
    // anchored at `offsetByUTF16`. Needed because CTRubyAnnotation attributes are applied
    // in UTF-16 units while kanjiRuns reports Character offsets.
    private static func nsRange(
        in surface: String,
        startChar: Int,
        endChar: Int,
        offsetByUTF16: Int
    ) -> NSRange {
        let startIndex = surface.index(surface.startIndex, offsetBy: startChar)
        let endIndex = surface.index(surface.startIndex, offsetBy: endChar)
        let utf16Start = surface.utf16.distance(from: surface.utf16.startIndex,
                                                to: startIndex.samePosition(in: surface.utf16)!)
        let utf16End = surface.utf16.distance(from: surface.utf16.startIndex,
                                              to: endIndex.samePosition(in: surface.utf16)!)
        return NSRange(location: offsetByUTF16 + utf16Start, length: utf16End - utf16Start)
    }
}
