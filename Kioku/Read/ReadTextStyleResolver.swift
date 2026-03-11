import Foundation
import UIKit

// Builds read-mode token styling independently from furigana overlay layout.
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

    // Produces the read-mode attributed string and token foreground map for one render pass.
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
            return ReadTextStylePayload(attributedText: attributedText, tokenForegroundByLocation: [:])
        }

        var tokenForegroundByLocation: [Int: UIColor] = [:]
        var colorAlternationIndex = 0

        for segmentRange in segmentationRanges {
            let nsRange = NSRange(segmentRange, in: text)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                continue
            }

            let segmentText = String(text[segmentRange])
            if shouldIgnoreTokenStyling(for: segmentText) {
                continue
            }

            let foregroundColor: UIColor?
            if isHighlightUnknownEnabled && unknownSegmentLocations.contains(nsRange.location) {
                foregroundColor = unknownTokenForegroundColor
            } else if isColorAlternationEnabled {
                foregroundColor = colorAlternationIndex.isMultiple(of: 2)
                    ? evenTokenForegroundColor
                    : oddTokenForegroundColor
            } else {
                foregroundColor = nil
            }

            if let foregroundColor {
                attributedText.addAttribute(.foregroundColor, value: foregroundColor, range: nsRange)
                for offset in 0..<nsRange.length {
                    tokenForegroundByLocation[nsRange.location + offset] = foregroundColor
                }
            }

            colorAlternationIndex += 1
        }

        return ReadTextStylePayload(
            attributedText: attributedText,
            tokenForegroundByLocation: tokenForegroundByLocation
        )
    }

    // Returns the alternating foreground color for even-indexed visible tokens.
    private var evenTokenForegroundColor: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemOrange : .systemRed
        }
    }

    // Returns the alternating foreground color for odd-indexed visible tokens.
    private var oddTokenForegroundColor: UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo
        }
    }

    // Returns the explicit foreground color used when the user enables unknown-token highlighting.
    private var unknownTokenForegroundColor: UIColor {
        /*
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemYellow : .systemOrange
        }
        */
        UIColor.label
    }

    // Skips whitespace and punctuation so token styling only affects lexical segments.
    private func shouldIgnoreTokenStyling(for segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }
}