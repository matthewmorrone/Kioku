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
        // Visual glyph width of the headword with no kern applied, so envelope bounds
        // describe what the user actually sees rather than segmentRect's advance which
        // includes the trailing envelope-padding kern.
        let visualHeadwordWidth: CGFloat

        // Envelope boundaries used by the overlap check — ruby extends past the headword when
        // it's wider, so each segment occupies max(visualKanji, ruby) horizontally. Using the
        // visual width (rather than segmentRect.maxX) prevents double-counting kern we already
        // inserted pre-layout as if it were part of the envelope.
        var envelopeMinX: CGFloat {
            furiganaFrame.isNull ? segmentRect.minX : min(segmentRect.minX, furiganaFrame.minX)
        }
        var envelopeMaxX: CGFloat {
            let kanjiVisualMaxX = segmentRect.minX + visualHeadwordWidth
            return furiganaFrame.isNull ? kanjiVisualMaxX : max(kanjiVisualMaxX, furiganaFrame.maxX)
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
        guard isVisualEnhancementsEnabled else { return false }

        let runs = collectFuriganaRunGeometry(in: textView, furiganaFont: furiganaFont)
        guard !runs.isEmpty else { return false }

        let lines = groupByLine(runs)
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
            // Tracks how far all subsequent frames have shifted due to kern applied earlier on
            // this line. Each kern insertion pushes every segment to its right by the same amount.
            var cumulativeShift: CGFloat = 0

            for i in 1..<sorted.count {
                let prev = sorted[i - 1]
                let curr = sorted[i]
                // firstRect(for:) doesn't account for trailing .kern on prev's last char when
                // computing curr's rect, so without this adjustment we'd pile fresh kern on top
                // of the kern pre-layout already applied. The real rendered position of curr is
                // curr.segmentRect.minX + (prev's trailing kern minus the base kerning baseline).
                let prevLastCharLoc = prev.segmentNSRange.location + prev.segmentNSRange.length - 1
                let trailingKern: CGFloat
                if prevLastCharLoc < (text as NSString).length,
                   let kernAttr = textView.textStorage.attribute(.kern, at: prevLastCharLoc, effectiveRange: nil) as? NSNumber {
                    trailingKern = CGFloat(kernAttr.doubleValue) - CGFloat(kerning)
                } else {
                    trailingKern = 0
                }
                let prevMaxX = prev.envelopeMaxX + cumulativeShift
                let currMinX = curr.envelopeMinX + trailingKern + cumulativeShift
                let overlap = prevMaxX + minGap - currMinX
                let prevText = (text as NSString).substring(with: prev.segmentNSRange)
                let currText = (text as NSString).substring(with: curr.segmentNSRange)
                if prev.segmentNSRange.location < 200 {
                    print("[post-layout] \(prevText)→\(currText) prevEnvMaxX=\(prevMaxX) currEnvMinX=\(currMinX) overlap=\(overlap) prev.segmentRect.maxX=\(prev.segmentRect.maxX) prev.visualHeadwordWidth=\(prev.visualHeadwordWidth) prev.furi.maxX=\(prev.furiganaFrame.isNull ? -1 : prev.furiganaFrame.maxX)")
                }
                guard overlap > 0 else { continue }

                // Insert kern after the last UTF-16 unit of the previous segment's headword.
                let lastCharLoc = prev.segmentNSRange.location + prev.segmentNSRange.length - 1
                guard lastCharLoc < (text as NSString).length else { continue }
                if prev.segmentNSRange.location < 200 {
                    let existingKernProbe = textView.textStorage.attribute(.kern, at: lastCharLoc, effectiveRange: nil)
                    print("[post-layout-existing] \(prevText) loc=\(lastCharLoc) existingKern=\(existingKernProbe as Any)")
                }
                let charRange = NSRange(location: lastCharLoc, length: 1)
                let existing = textView.textStorage.attribute(.kern, at: lastCharLoc, effectiveRange: nil)
                let existingKern = (existing as? NSNumber).map { CGFloat($0.doubleValue) } ?? CGFloat(kerning)
                corrections.append((charRange, existingKern + overlap))
                cumulativeShift += overlap
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

            let baseFont = UIFont.systemFont(ofSize: textSize)
            // Measured with no kern so it reflects the kanji's visible width, not the advance
            // inflated by pre-layout envelope padding. Used both to center the ruby and to
            // bound the envelope.
            let visualHeadwordWidth = measureTextWidth(String(text[surfaceRange]), font: baseFont, kerning: 0)

            var furiganaFrame: CGRect = .null
            if !skipFurigana,
               let furigana = furiganaBySegmentLocation[nsRange.location],
               !furigana.isEmpty,
               let length = furiganaLengthBySegmentLocation[nsRange.location],
               length > 0,
               length == nsRange.length,
               let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                   surface: String(text[surfaceRange]),
                   reading: furigana
               ) {
                let furiganaWidth = measureTextWidth(displayReading, font: furiganaFont, kerning: 0)
                let furiganaX = segmentRect.minX + visualHeadwordWidth / 2 - furiganaWidth / 2
                furiganaFrame = CGRect(
                    x: furiganaX,
                    y: max(segmentRect.minY - furiganaFont.lineHeight - CGFloat(furiganaGap), 0),
                    width: furiganaWidth,
                    height: furiganaFont.lineHeight
                )
            }

            runs.append(FuriganaRunGeometry(
                segmentNSRange: nsRange,
                segmentRect: segmentRect,
                furiganaFrame: furiganaFrame,
                visualHeadwordWidth: visualHeadwordWidth
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
