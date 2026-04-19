import UIKit

// Post-layout pass that inserts exclusion paths at the left edge of any visual line whose first
// segment has ruby wider than its headword. The exclusion carves out a rectangle at that line's
// Y range, which causes TextKit to shift the line's glyphs right by the exclusion width so the
// segment's envelope aligns with the container's left edge instead of overflowing past it.
// All geometry is sourced directly from TextKit so it stays in text-container coordinates
// end-to-end — no view-space round-trip (see CLAUDE.md §9).
extension FuriganaTextRenderer {

    // Builds and applies exclusion paths for each line whose first segment's ruby overhangs left.
    // Returns true when any exclusion changed so the caller can trigger a relayout pass.
    func applyLeftInsetExclusionsForWideRuby(
        to textView: UITextView,
        furiganaFont: UIFont
    ) -> Bool {
        guard isVisualEnhancementsEnabled,
              furiganaBySegmentLocation.isEmpty == false,
              let tlm = textView.textLayoutManager,
              let tcm = tlm.textContentManager else {
            return clearExclusionsIfNeeded(on: textView)
        }

        let baseFont = UIFont.systemFont(ofSize: textSize)

        // Precompute the left-half overhang for each segment that has wide ruby. Segments with
        // no furigana, or whose ruby fits inside the headword, contribute no overhang.
        let overhangBySegmentLocation = computeOverhangsBySegmentLocation(baseFont: baseFont, furiganaFont: furiganaFont)
        guard overhangBySegmentLocation.isEmpty == false else {
            return clearExclusionsIfNeeded(on: textView)
        }

        // Iterate only the wide-furi segments, query their current TextKit geometry, and
        // emit an exclusion only when the segment actually sits at a line's left edge (its
        // glyph origin is at container x=0, i.e. text-view x=inset.left). Identifying
        // line-starts this way is robust to TextKit's own reflow quirks — we don't have to
        // reason about paragraphs, soft wraps, or blank-line handling separately.
        var newExclusions: [UIBezierPath] = []
        let lineStartTolerance: CGFloat = 0.5
        for (location, overhang) in overhangBySegmentLocation {
            guard let length = furiganaLengthBySegmentLocation[location] else { continue }
            let nsRange = NSRange(location: location, length: length)
            guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else { continue }

            // segmentRectInTextView returns text-view coords. Convert the one boundary we need
            // (the segment's left edge) into container coords for the line-start check. This is
            // the only view→container conversion required; the exclusion itself is fully built
            // from TextKit's own line-fragment geometry below.
            let segmentMinXInContainer = segmentRect.minX - textView.textContainerInset.left
            guard segmentMinXInContainer <= lineStartTolerance else { continue }

            // Query the TextKit line fragment containing this segment so the exclusion's Y/height
            // come straight from TextKit in container coords — no inset math, matching the
            // coordinate-pipeline invariant in CLAUDE.md §9.
            guard let lineGeometry = lineFragmentContainerGeometry(
                for: location,
                in: tlm,
                tcm: tcm
            ) else { continue }

            let rect = CGRect(
                x: 0,
                y: lineGeometry.origin.y,
                width: overhang,
                height: lineGeometry.height
            )
            newExclusions.append(UIBezierPath(rect: rect))
        }

        return replaceExclusionsIfChanged(on: textView, with: newExclusions)
    }

    // Locates the TextKit line fragment that contains the given UTF-16 location and returns
    // its bounds in text-container coords. Returns nil when the location is outside the laid
    // out range. All Y/height values are sourced directly from TextKit — no view-space math.
    private func lineFragmentContainerGeometry(
        for utf16Location: Int,
        in tlm: NSTextLayoutManager,
        tcm: NSTextContentManager
    ) -> CGRect? {
        let docStart = tcm.documentRange.location
        var result: CGRect?
        tlm.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let fragmentOffset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            let fragmentLength = tcm.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation)
            guard utf16Location >= fragmentOffset, utf16Location < fragmentOffset + fragmentLength else {
                return true
            }
            let relativeLocation = utf16Location - fragmentOffset
            for lineFragment in fragment.textLineFragments {
                let lineRange = lineFragment.characterRange
                guard relativeLocation >= lineRange.location,
                      relativeLocation < lineRange.location + lineRange.length else { continue }
                let bounds = lineFragment.typographicBounds
                result = CGRect(
                    x: bounds.origin.x,
                    y: fragment.layoutFragmentFrame.origin.y + bounds.origin.y,
                    width: bounds.width,
                    height: bounds.height
                )
                return false
            }
            return false
        }
        return result
    }

    // Returns the half-overhang (furiWidth - headwordWidth) / 2 for every segment whose ruby
    // extends past its headword. Only positive values are included so callers can treat a
    // missing key as "no overhang".
    private func computeOverhangsBySegmentLocation(baseFont: UIFont, furiganaFont: UIFont) -> [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        for (location, reading) in furiganaBySegmentLocation {
            guard reading.isEmpty == false,
                  let length = furiganaLengthBySegmentLocation[location],
                  length > 0 else { continue }
            let nsRange = NSRange(location: location, length: length)
            guard let surfaceRange = Range(nsRange, in: text) else { continue }
            let headwordWidth = measureTextWidth(String(text[surfaceRange]), font: baseFont, kerning: 0)
            let furiganaWidth = measureTextWidth(reading, font: furiganaFont, kerning: 0)
            let overhang = (furiganaWidth - headwordWidth) / 2
            if overhang > 0 {
                result[location] = ceil(overhang)
            }
        }
        return result
    }

    // Updates textContainer.exclusionPaths only when the new set differs from the current one,
    // so identical repeat renders don't force a pointless relayout.
    private func replaceExclusionsIfChanged(on textView: UITextView, with paths: [UIBezierPath]) -> Bool {
        let existing = textView.textContainer.exclusionPaths
        let existingRects = existing.map { $0.bounds }
        let newRects = paths.map { $0.bounds }
        guard existingRects != newRects else { return false }
        textView.textContainer.exclusionPaths = paths
        return true
    }

    // Clears any previously-applied exclusion paths when the current text no longer needs them.
    private func clearExclusionsIfNeeded(on textView: UITextView) -> Bool {
        guard textView.textContainer.exclusionPaths.isEmpty == false else { return false }
        textView.textContainer.exclusionPaths = []
        return true
    }
}
