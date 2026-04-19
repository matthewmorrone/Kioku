import Foundation
import UIKit

// Builds read-mode segment styling independently from furigana overlay layout.
struct ReadTextStyleResolver {
    let text: String
    let segmentationRanges: [Range<String.Index>]
    let textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let isLineWrappingEnabled: Bool
    let isVisualEnhancementsEnabled: Bool
    let isColorAlternationEnabled: Bool
    let isHighlightUnknownEnabled: Bool
    let unknownSegmentLocations: Set<Int>
    // UTF-16 segment start locations changed by a pending LLM correction, rendered with a glow.
    let changedSegmentLocations: Set<Int>
    // Subset of changedSegmentLocations where only the furigana reading changed (surface unchanged).
    // These locations color only furigana; the segment text stays its normal color.
    let changedReadingLocations: Set<Int>
    // User-configured colors for even/odd segment alternation. When nil, falls back to system defaults.
    let customEvenSegmentColor: UIColor?
    let customOddSegmentColor: UIColor?
    // Furigana data used to compute envelope padding so wide readings don't visually overlap neighbors.
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    var textAlignment: NSTextAlignment = .natural

    // Produces the read-mode attributed string and segment foreground map for one render pass.
    func makePayload() -> ReadTextStylePayload {
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing + (baseFont.lineHeight * 0.5)
        paragraphStyle.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping
        paragraphStyle.alignment = textAlignment

        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .kern: kerning,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor.label,
            ]
        )

        var segmentForegroundByLocation: [Int: UIColor] = [:]
        var colorAlternationIndex = 0

        if isVisualEnhancementsEnabled {
            for segmentRange in segmentationRanges {
                let nsRange = NSRange(segmentRange, in: text)
                if nsRange.location == NSNotFound || nsRange.length == 0 {
                    continue
                }

                let segmentText = String(text[segmentRange])
                if shouldIgnoreSegmentStyling(for: segmentText) {
                    continue
                }

                let foregroundColor: UIColor?
                if isHighlightUnknownEnabled && unknownSegmentLocations.contains(nsRange.location) {
                    foregroundColor = unknownSegmentForegroundColor
                } else if isColorAlternationEnabled {
                    foregroundColor = colorAlternationIndex.isMultiple(of: 2)
                        ? evenSegmentForegroundColor
                        : oddSegmentForegroundColor
                } else {
                    foregroundColor = nil
                }

                if let foregroundColor {
                    attributedText.addAttribute(.foregroundColor, value: foregroundColor, range: nsRange)
                    for offset in 0..<nsRange.length {
                        segmentForegroundByLocation[nsRange.location + offset] = foregroundColor
                    }
                }

                colorAlternationIndex += 1
            }
        }

        // Apply changed-segment styling after all other styling so it always wins.
        // This is functional UI state (pending LLM confirmation), not a visual preference.
        // Reading-only changes color the furigana (via segmentForegroundByLocation) but not the text.
        // Boundary changes (surface changed) color both the text and the furigana.
        if changedSegmentLocations.isEmpty == false {
            for segmentRange in segmentationRanges {
                let nsRange = NSRange(segmentRange, in: text)
                if nsRange.location == NSNotFound || nsRange.length == 0 { continue }
                guard changedSegmentLocations.contains(nsRange.location) else { continue }
                let isReadingOnly = changedReadingLocations.contains(nsRange.location)
                if isReadingOnly == false {
                    attributedText.addAttribute(.foregroundColor, value: changedSegmentColor, range: nsRange)
                    attributedText.addAttribute(.shadow, value: changedSegmentGlow, range: nsRange)
                }
                // All changed locations (boundary or reading-only) tint the furigana green.
                for offset in 0..<nsRange.length {
                    segmentForegroundByLocation[nsRange.location + offset] = changedSegmentColor
                }
            }
        }

        // Envelope padding: when a segment's furigana is wider than its headword, add trailing kern
        // to the current segment and the previous segment so the reading has room to breathe without
        // visually overlapping its neighbors.
        if isVisualEnhancementsEnabled && !furiganaBySegmentLocation.isEmpty {
            applyEnvelopePadding(to: attributedText, baseFont: baseFont)
        }

        return ReadTextStylePayload(
            attributedText: attributedText,
            segmentForegroundByLocation: segmentForegroundByLocation
        )
    }

    // Iterates segments that have furigana wider than their headword and injects trailing kern so the
    // reading overhang lands in empty space rather than on top of the adjacent segment's glyphs.
    // Takes the max when multiple segments compete for kern on the same trailing character position.
    private func applyEnvelopePadding(to attributedText: NSMutableAttributedString, baseFont: UIFont) {
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        // Maps last-UTF16-unit location → extra kern to add.
        var additionalKernByLocation: [Int: CGFloat] = [:]

        for (segmentIndex, segmentRange) in segmentationRanges.enumerated() {
            let nsRange = NSRange(segmentRange, in: text)
            guard nsRange.location != NSNotFound, nsRange.length > 0,
                  let furigana = furiganaBySegmentLocation[nsRange.location],
                  !furigana.isEmpty,
                  let furiganaLength = furiganaLengthBySegmentLocation[nsRange.location],
                  furiganaLength > 0,
                  let surfaceRange = Range(nsRange, in: text),
                  let displayReading = FuriganaAttributedString.normalizedDisplayReading(
                      surface: String(text[surfaceRange]),
                      reading: furigana
                  ) else { continue }

            let headwordWidth = measureWidth(String(text[surfaceRange]), font: baseFont)
            let furiganaWidth = measureWidth(displayReading, font: furiganaFont)
            guard furiganaWidth > headwordWidth else { continue }

            let overhang = ceil((furiganaWidth - headwordWidth) / 2)

            // Right overhang: pad after the current segment.
            let currentLastLoc = nsRange.location + nsRange.length - 1
            additionalKernByLocation[currentLastLoc] = max(
                additionalKernByLocation[currentLastLoc] ?? 0, overhang
            )

            // Left overhang: pad after the previous segment so the current segment starts further right.
            // Skip when the previous segment ends in punctuation — adding kern to a trailing comma or
            // period visually attaches it to the following furigana word's envelope.
            if segmentIndex > 0 {
                let prevNSRange = NSRange(segmentationRanges[segmentIndex - 1], in: text)
                if prevNSRange.location != NSNotFound, prevNSRange.length > 0 {
                    let prevLastLoc = prevNSRange.location + prevNSRange.length - 1
                    if let prevLastCharRange = Range(NSRange(location: prevLastLoc, length: 1), in: text) {
                        let prevLastChar = String(text[prevLastCharRange])
                        let endsInNonLexical = prevLastChar.unicodeScalars.allSatisfy {
                            Self.nonLexicalScalars.contains($0)
                        }
                        if !endsInNonLexical {
                            additionalKernByLocation[prevLastLoc] = max(
                                additionalKernByLocation[prevLastLoc] ?? 0, overhang
                            )
                        }
                    }
                }
            }
        }

        let textLength = (text as NSString).length
        for (location, extraKern) in additionalKernByLocation {
            guard location < textLength else { continue }
            let charRange = NSRange(location: location, length: 1)
            let charText = (text as NSString).substring(with: charRange)
            if location < 200 {
                print("[pre-layout] char=\(charText) loc=\(location) extraKern=\(extraKern) totalKern=\(CGFloat(kerning) + extraKern)")
            }
            // Stack on top of the global base kern that was set for the whole string.
            attributedText.addAttribute(.kern, value: CGFloat(kerning) + extraKern, range: charRange)
        }
    }

    // Measures the rendered width of a string using font metrics, independent of layout state.
    private func measureWidth(_ value: String, font: UIFont) -> CGFloat {
        guard !value.isEmpty else { return 0 }
        return ceil((value as NSString).size(withAttributes: [.font: font]).width)
    }

    // Returns the alternating foreground color for even-indexed visible segments.
    // Uses the user-configured custom color when set; falls back to system orange/red.
    private var evenSegmentForegroundColor: UIColor {
        if let customEvenSegmentColor { return customEvenSegmentColor }
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemOrange : .systemRed
        }
    }

    // Returns the alternating foreground color for odd-indexed visible segments.
    // Uses the user-configured custom color when set; falls back to system cyan/indigo.
    private var oddSegmentForegroundColor: UIColor {
        if let customOddSegmentColor { return customOddSegmentColor }
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo
        }
    }

    // Returns the explicit foreground color used when the user enables unknown-segment highlighting.
    private var unknownSegmentForegroundColor: UIColor {
        /*
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemYellow : .systemOrange
        }
        */
        UIColor.label
    }

    // Glow shadow for segments changed by a pending LLM correction.
    // shadowOffset = .zero centers the blur around the glyphs, creating a bloom effect.
    // Using the same color as the foreground makes the glow visibly tied to the tinted text.
    private var changedSegmentGlow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = changedSegmentColor.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = .zero
        return shadow
    }

    // Foreground color for segments changed by a pending LLM correction.
    // Mint is distinct from the alternating orange/cyan/red/indigo palette and
    // the yellow selection rect drawn by FuriganaOverlayView.
    private var changedSegmentColor: UIColor {
        UIColor.systemGreen
    }

    // Skips whitespace and punctuation so segment styling only affects lexical segments.
    private func shouldIgnoreSegmentStyling(for segmentText: String) -> Bool {
        return segmentText.unicodeScalars.allSatisfy { Self.nonLexicalScalars.contains($0) }
    }

    // Character set covering whitespace, punctuation, and symbols — including CJK brackets and
    // delimiters that Foundation's punctuationCharacters may not classify correctly.
    private static let nonLexicalScalars: CharacterSet = {
        var cs = CharacterSet.whitespacesAndNewlines
        cs.formUnion(.punctuationCharacters)
        cs.formUnion(.symbols)
        // Explicitly add common Japanese punctuation and brackets to guard against
        // Foundation misclassifying CJK Symbols and Punctuation block characters.
        for scalar in "「」『』【】〔〕〈〉《》（）、。・〜…―～".unicodeScalars {
            cs.insert(scalar)
        }
        return cs
    }()
}