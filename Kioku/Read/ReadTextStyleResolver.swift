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

    // Produces the read-mode attributed string and segment foreground map for one render pass.
    func makePayload() -> ReadTextStylePayload {
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing + (baseFont.lineHeight * 0.5)
        paragraphStyle.lineBreakMode = isLineWrappingEnabled ? .byWordWrapping : .byClipping

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

        return ReadTextStylePayload(
            attributedText: attributedText,
            segmentForegroundByLocation: segmentForegroundByLocation
        )
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
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }
}