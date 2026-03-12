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

        guard isVisualEnhancementsEnabled else {
            return ReadTextStylePayload(attributedText: attributedText, segmentForegroundByLocation: [:])
        }

        var segmentForegroundByLocation: [Int: UIColor] = [:]
        var colorAlternationIndex = 0

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

        return ReadTextStylePayload(
            attributedText: attributedText,
            segmentForegroundByLocation: segmentForegroundByLocation
        )
    }

    // Returns the alternating foreground color for even-indexed visible segments.
    private var evenSegmentForegroundColor: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemOrange : .systemRed
        }
    }

    // Returns the alternating foreground color for odd-indexed visible segments.
    private var oddSegmentForegroundColor: UIColor {
        UIColor { traitCollection in
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

    // Skips whitespace and punctuation so segment styling only affects lexical segments.
    private func shouldIgnoreSegmentStyling(for segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }
}