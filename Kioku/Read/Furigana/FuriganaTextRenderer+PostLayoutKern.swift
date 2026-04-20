import UIKit

// Post-layout ruby kern pass: after TextKit has produced glyph geometry, walks furigana segments
// line by line left-to-right and inserts trailing kern after any segment whose furigana frame
// would otherwise overlap the next segment's furigana frame on the same line.
// This is the pass that pre-layout envelope padding cannot do — line breaks are not known until
// after layout, so only a post-layout pass can catch soft-wrapped line transitions correctly.
extension FuriganaTextRenderer {

    // Pairs a segment's NSRange with its laid-out headword and furigana geometry.
    // Segments without furigana report .null for furiganaFrame so the overlap pass can still
    // compare a wide-furi segment's envelope against a kana-only neighbor's headword rect.
    struct FuriganaRunGeometry {
        let segmentNSRange: NSRange
        let segmentRect: CGRect
        let furiganaFrame: CGRect
        // Right edge of this segment's kanji advance box + baseline kerning — the x where the
        // next segment would naturally start if nothing else intervened. Used as one half of the
        // envelope's right edge; the other half is the ruby's rightmost point.
        let lastCharMaxX: CGFloat

        // Envelope = kanji territory ∪ ruby territory. Size is a property of the segment's
        // content (kanji width and ruby width) and therefore invariant with respect to whether
        // ruby spacing is applied — spacing only shifts the envelope's POSITION to prevent
        // overlap with neighbors.
        var envelopeMinX: CGFloat {
            furiganaFrame.isNull ? segmentRect.minX : min(segmentRect.minX, furiganaFrame.minX)
        }
        var envelopeMaxX: CGFloat {
            furiganaFrame.isNull ? lastCharMaxX : max(lastCharMaxX, furiganaFrame.maxX)
        }
        // Y used for line grouping — always the headword baseline so runs with and without
        // furigana group together on the same visual line (a wide-furi segment and a kana-only
        // segment must be recognized as being on the same line to be paired for overlap checks).
        var groupingY: CGFloat { segmentRect.minY }
    }

    // Applies trailing kern to prevent adjacent furigana frames from overlapping on the same line.
    // Modifies textView.textStorage directly and returns true when any corrections were applied
    // so the caller can trigger a second ensureLayout pass.
    func applyPostLayoutRubyKern(to textView: UITextView, furiganaFont: UIFont) -> Bool {
        guard isVisualEnhancementsEnabled, isRubySpacingEnabled else { return false }

        let runs = collectFuriganaRunGeometry(in: textView, furiganaFont: furiganaFont)
        guard !runs.isEmpty else { return false }

        let lines = groupByLine(runs)
        // Per-segment envelope dump: prints left (min) and right (max) x for every laid-out
        // segment so overlapping pairs can be identified from the console.
        for (lineIndex, line) in lines.enumerated() {
            let sortedForDump = line.sorted { $0.envelopeMinX < $1.envelopeMinX }
            for run in sortedForDump {
                let surface = (text as NSString).substring(with: run.segmentNSRange)
                print("[seg-envelope] line=\(lineIndex) surface=\(surface) leftX=\(run.envelopeMinX) rightX=\(run.envelopeMaxX)")
            }
        }
        // No forced gap between adjacent envelopes — TextKit already places glyphs tight and
        // we only want to intervene when there's actual overlap. A non-zero gap here accumulates
        // across a line: every adjacent pair gets a small kern, each of which shifts all later
        // segments on the line by that amount, making their debug envelopes drift right.
        let minGap: CGFloat = 0
        var corrections: [(NSRange, CGFloat)] = []

        for line in lines {
            // Sort by envelope left edge so a wide-ruby segment whose furi overflows past its
            // kanji still lands in the correct order relative to a kana-only neighbor.
            let sorted = line.sorted { $0.envelopeMinX < $1.envelopeMinX }

            for i in 1..<sorted.count {
                let prev = sorted[i - 1]
                let curr = sorted[i]
                let overlap = prev.envelopeMaxX + minGap - curr.envelopeMinX
                guard overlap > 0 else { continue }

                // Insert kern after the last UTF-16 unit of the previous segment's headword.
                let lastCharLoc = prev.segmentNSRange.location + prev.segmentNSRange.length - 1
                guard lastCharLoc < (text as NSString).length else { continue }
                let charRange = NSRange(location: lastCharLoc, length: 1)
                let existing = textView.textStorage.attribute(.kern, at: lastCharLoc, effectiveRange: nil)
                let existingKern = (existing as? NSNumber).map { CGFloat($0.doubleValue) } ?? CGFloat(kerning)
                let newKern = existingKern + overlap
                let prevSurface = (text as NSString).substring(with: prev.segmentNSRange)
                let currSurface = (text as NSString).substring(with: curr.segmentNSRange)
                print("[seg-kern] \(prevSurface)→\(currSurface) overlap=\(overlap) existingKern=\(existingKern) newKern=\(newKern) at loc=\(lastCharLoc)")
                corrections.append((charRange, newKern))
            }
        }

        guard !corrections.isEmpty else { return false }

        textView.textStorage.beginEditing()
        for (range, kern) in corrections {
            textView.textStorage.addAttribute(.kern, value: kern, range: range)
        }
        textView.textStorage.endEditing()
        return true
    }

    // Builds FuriganaRunGeometry for every segment currently laid out, not just those with
    // furigana. Kana-only segments are included because a wide-ruby segment's envelope can still
    // overlap a kana neighbor's headword; the overlap pass needs both to see the collision.
    // Mirrors the frame computation used by the main overlay loop so coordinates are consistent.
    private func collectFuriganaRunGeometry(
        in textView: UITextView,
        furiganaFont: UIFont
    ) -> [FuriganaRunGeometry] {
        var runs: [FuriganaRunGeometry] = []
        let blankedSelectedRange: NSRange? = (blankSelectedSegmentLocation == selectedSegmentLocation)
            ? selectedSegmentNSRangeForPostLayout() : nil

        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }

            // Segments whose furigana is hidden (blanked selected segment) still have a headword
            // rect the neighbors should respect, so treat them as no-furigana runs instead of
            // skipping them entirely.
            let skipFurigana = blankedSelectedRange.map { NSIntersectionRange(nsRange, $0).length > 0 } ?? false

            guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange),
                  let surfaceRange = Range(nsRange, in: text) else { continue }

            // TextKit-authoritative right edge of the last character's glyph advance box. This
            // is the segment's visible right edge — no kerning baked in, so the envelope's size
            // remains a property of the glyphs alone and doesn't shift when spacing changes.
            let lastCharLocation = nsRange.location + nsRange.length - 1
            let lastCharRange = NSRange(location: lastCharLocation, length: 1)
            let lastCharMaxX = segmentRectInTextView(textView: textView, nsRange: lastCharRange)?.maxX
                ?? segmentRect.maxX
            let headwordVisualWidth = lastCharMaxX - segmentRect.minX

            var furiganaFrame: CGRect = .null
            if !skipFurigana,
               let furigana = furiganaBySegmentLocation[nsRange.location],
               !furigana.isEmpty,
               let length = furiganaLengthBySegmentLocation[nsRange.location],
               length > 0 {
                // Ruby centers over just the kanji run it actually covers — not the entire
                // segment — so merged segments like "力になりたい" with furigana only on 力
                // still project a ruby frame whose left/right match the visible reading.
                let kanjiNSRange = NSRange(location: nsRange.location, length: length)
                guard let kanjiRange = Range(kanjiNSRange, in: text),
                      let kanjiRect = segmentRectInTextView(textView: textView, nsRange: kanjiNSRange),
                      let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                          surface: String(text[kanjiRange]),
                          reading: furigana
                      )
                else {
                    runs.append(FuriganaRunGeometry(
                        segmentNSRange: nsRange,
                        segmentRect: segmentRect,
                        furiganaFrame: .null,
                        lastCharMaxX: lastCharMaxX
                    ))
                    continue
                }

                // Use the kanji run's final-character firstRect for its visual right edge so
                // centering ignores trailing kern on that character.
                let kanjiLastCharLocation = kanjiNSRange.location + kanjiNSRange.length - 1
                let kanjiLastCharRange = NSRange(location: kanjiLastCharLocation, length: 1)
                let kanjiVisualMaxX = segmentRectInTextView(textView: textView, nsRange: kanjiLastCharRange)?.maxX
                    ?? kanjiRect.maxX
                let kanjiVisualWidth = kanjiVisualMaxX - kanjiRect.minX

                let furiganaWidth = measureTextWidth(displayReading, font: furiganaFont, kerning: 0)
                let furiganaX = kanjiRect.minX + kanjiVisualWidth / 2 - furiganaWidth / 2
                furiganaFrame = CGRect(
                    x: furiganaX,
                    y: max(kanjiRect.minY - furiganaFont.lineHeight - CGFloat(furiganaGap), 0),
                    width: furiganaWidth,
                    height: furiganaFont.lineHeight
                )
            }

            runs.append(FuriganaRunGeometry(
                segmentNSRange: nsRange,
                segmentRect: segmentRect,
                furiganaFrame: furiganaFrame,
                lastCharMaxX: lastCharMaxX
            ))
        }

        return runs
    }

    // Groups runs into visual lines using groupingY (furi.minY when present, segment.minY when
    // the segment has no furigana) within a small tolerance.
    private func groupByLine(_ runs: [FuriganaRunGeometry]) -> [[FuriganaRunGeometry]] {
        let sorted = runs.sorted { $0.groupingY < $1.groupingY }
        let lineTolerance: CGFloat = 2.0
        var lines: [[FuriganaRunGeometry]] = []
        var currentLine: [FuriganaRunGeometry] = []
        var currentLineY: CGFloat = -.greatestFiniteMagnitude

        for run in sorted {
            let y = run.groupingY
            if abs(y - currentLineY) > lineTolerance {
                if !currentLine.isEmpty { lines.append(currentLine) }
                currentLine = [run]
                currentLineY = y
            } else {
                currentLine.append(run)
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        return lines
    }

    // Resolves the selected segment NSRange for the post-layout pass, mirroring the logic in
    // selectedSegmentNSRange(in:) without needing to duplicate its full signature.
    private func selectedSegmentNSRangeForPostLayout() -> NSRange? {
        if let override = selectedHighlightRangeOverride,
           override.location != NSNotFound,
           override.length > 0,
           override.upperBound <= (text as NSString).length {
            return override
        }
        guard let loc = selectedSegmentLocation else { return nil }
        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == loc, nsRange.length > 0 { return nsRange }
        }
        return nil
    }

}
