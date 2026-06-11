import UIKit

// Debug-only logging helpers extracted from FuriganaTextRenderer so the main renderer stays under
// the 800-line warning threshold. logLeftInsetGuide emits per-segment position data when the
// left-inset debug guide is enabled in Settings; in production the gate short-circuits before it
// runs, so moving it here has no behavioral effect.
extension FuriganaTextRenderer {

    // Logs per-segment position data for every line-start segment near the left inset.
    // Kept out of updateUIView so the hot path stays clean.
    func logLeftInsetGuide(textView: UITextView) {
        let insetLeft = textView.textContainerInset.left
        let furiganaFont = UIFont.systemFont(ofSize: textSize * TypographySettings.furiganaSizeFactor)
        let overhangsByLocation = lineStartOverhangsByLocation(furiganaFont: furiganaFont)
        NSLog("[inset-guide] insetLeft=%.2f", Double(insetLeft))
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for segmentRange in segmentationRanges {
            let segmentText = String(text[segmentRange])
            guard !segmentText.unicodeScalars.allSatisfy({ ignoredScalars.contains($0) }) else { continue }
            let nsRange = NSRange(segmentRange, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0 else { continue }
            guard let segmentRect = segmentRectInTextView(textView: textView, nsRange: nsRange) else { continue }
            let lastCharMaxX = segmentRectInTextView(
                textView: textView,
                nsRange: NSRange(location: nsRange.location + nsRange.length - 1, length: 1)
            )?.maxX ?? segmentRect.maxX
            var envelopeMinX = segmentRect.minX
            var envelopeMaxX = lastCharMaxX
            if let reading = furiganaBySegmentLocation[nsRange.location],
               !reading.isEmpty,
               let kanjiLength = furiganaLengthBySegmentLocation[nsRange.location], kanjiLength > 0,
               let kanjiSurfaceRange = Range(NSRange(location: nsRange.location, length: kanjiLength), in: text),
               let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                   surface: String(text[kanjiSurfaceRange]), reading: reading
               ),
               let kanjiRect = segmentRectInTextView(
                   textView: textView,
                   nsRange: NSRange(location: nsRange.location, length: kanjiLength)
               ) {
                let kanjiLastMaxX = segmentRectInTextView(
                    textView: textView,
                    nsRange: NSRange(location: nsRange.location + kanjiLength - 1, length: 1)
                )?.maxX ?? kanjiRect.maxX
                let kanjiMidX = kanjiRect.minX + (kanjiLastMaxX - kanjiRect.minX) / 2
                let furiWidth = measureTextWidth(displayReading, font: furiganaFont, kerning: 0)
                envelopeMinX = min(envelopeMinX, kanjiMidX - furiWidth / 2)
                envelopeMaxX = max(envelopeMaxX, kanjiMidX + furiWidth / 2)
            }
            let overhang = overhangsByLocation[nsRange.location] ?? 0
            guard min(abs(envelopeMinX - insetLeft), abs(segmentRect.minX - insetLeft)) < 15.0 else { continue }
            NSLog("[inset-guide] seg=%@ loc=%d segMinX=%.2f envMinX=%.2f envMaxX=%.2f overhang=%.2f Δ(env-inset)=%.2f y=%.1f",
                  segmentText, nsRange.location,
                  Double(segmentRect.minX), Double(envelopeMinX), Double(envelopeMaxX),
                  Double(overhang), Double(envelopeMinX - insetLeft), Double(segmentRect.midY))
        }
    }
}
