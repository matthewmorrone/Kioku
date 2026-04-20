import SwiftUI
import UIKit

// Renders the live typography preview in the Settings typography section using the same
// FuriganaTextRenderer that powers the read tab, eliminating rendering divergence.
struct SettingsPreviewRenderer: View {

    // Preview text with hardcoded furigana readings.
    static let previewText = "情報処理技術者試験対策資料を精読し、概念理解を深める。志と力を承る。"

    private static let furigana: [(word: String, reading: String)] = [
        ("情報", "じょうほう"),
        ("処理", "しょり"),
        ("技術者", "ぎじゅつしゃ"),
        ("試験", "しけん"),
        ("対策", "たいさく"),
        ("資料", "しりょう"),
        ("精読", "せいどく"),
        ("概念", "がいねん"),
        ("理解", "りかい"),
        ("深める", "ふかめる"),
        ("志", "こころざし"),
        ("力", "ちから"),
        ("承る", "うけたまわる"),
    ]

    @Binding var textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let furiganaGap: Double
    let debugFuriganaRects: Bool
    let debugHeadwordRects: Bool
    let debugHeadwordLineBands: Bool
    let debugFuriganaLineBands: Bool
    let debugBisectors: Bool
    let debugEnvelopeRects: Bool

    // Builds segmentation ranges that treat each furigana word as its own segment,
    // with non-furigana runs as separate segments so every character is covered.
    private var segmentationRanges: [Range<String.Index>] {
        let text = Self.previewText
        let nsText = text as NSString
        var ranges: [(location: Int, length: Int)] = []

        // Find all furigana word positions.
        for (word, _) in Self.furigana {
            let r = nsText.range(of: word)
            if r.location != NSNotFound {
                ranges.append((r.location, r.length))
            }
        }
        ranges.sort { $0.location < $1.location }

        // Fill gaps between furigana words with non-furigana segments. Split each gap on
        // sentence punctuation so 、。！？ end up as their own segments instead of glued
        // to the kana next to them — matches the read tab's segmentation where punctuation
        // is always its own token.
        var result: [Range<String.Index>] = []
        var cursor = 0
        for r in ranges {
            if r.location > cursor {
                appendGapSegments(from: cursor, to: r.location, in: text, into: &result)
            }
            let wordNS = NSRange(location: r.location, length: r.length)
            if let wordRange = Range(wordNS, in: text) {
                result.append(wordRange)
            }
            cursor = r.location + r.length
        }
        if cursor < nsText.length {
            appendGapSegments(from: cursor, to: nsText.length, in: text, into: &result)
        }
        return result
    }

    // Breaks a UTF-16 gap range into segments, emitting each sentence-punctuation character as
    // its own segment and grouping all other characters into contiguous text-run segments.
    private func appendGapSegments(
        from startOffset: Int,
        to endOffset: Int,
        in text: String,
        into result: inout [Range<String.Index>]
    ) {
        let nsText = text as NSString
        var runStart: Int? = startOffset
        var cursor = startOffset

        while cursor < endOffset {
            let charRange = nsText.rangeOfComposedCharacterSequence(at: cursor)
            let charText = nsText.substring(with: charRange)
            let isPunctuation = Self.isStandaloneSegmentPunctuation(charText)

            if isPunctuation {
                if let runFrom = runStart, runFrom < charRange.location {
                    let runNS = NSRange(location: runFrom, length: charRange.location - runFrom)
                    if let runRange = Range(runNS, in: text) {
                        result.append(runRange)
                    }
                }
                if let punctRange = Range(charRange, in: text) {
                    result.append(punctRange)
                }
                runStart = charRange.location + charRange.length
            } else if runStart == nil {
                runStart = charRange.location
            }

            cursor = charRange.location + charRange.length
        }

        if let runFrom = runStart, runFrom < endOffset {
            let tailNS = NSRange(location: runFrom, length: endOffset - runFrom)
            if let tailRange = Range(tailNS, in: text) {
                result.append(tailRange)
            }
        }
    }

    // Defers to the read segmenter's shared boundary set so the preview splits on exactly the
    // same characters as the real segmentation path — no parallel list to drift out of sync.
    private static func isStandaloneSegmentPunctuation(_ grapheme: String) -> Bool {
        guard grapheme.count == 1, let char = grapheme.first else { return false }
        return Segmenter.boundaryCharacters.contains(char)
    }

    // Maps segment UTF-16 start locations to their furigana readings.
    private var furiganaBySegmentLocation: [Int: String] {
        let nsText = Self.previewText as NSString
        var map: [Int: String] = [:]
        for (word, reading) in Self.furigana {
            let r = nsText.range(of: word)
            if r.location != NSNotFound {
                map[r.location] = reading
            }
        }
        return map
    }

    // Maps segment UTF-16 start locations to their UTF-16 lengths.
    private var furiganaLengthBySegmentLocation: [Int: Int] {
        let nsText = Self.previewText as NSString
        var map: [Int: Int] = [:]
        for (word, _) in Self.furigana {
            let r = nsText.range(of: word)
            if r.location != NSNotFound {
                map[r.location] = r.length
            }
        }
        return map
    }

    var body: some View {
        FuriganaTextRenderer(
            isActive: true,
            isOverlayFrozen: false,
            text: Self.previewText,
            isLineWrappingEnabled: true,
            segmentationRanges: segmentationRanges,
            selectedSegmentLocation: nil,
            blankSelectedSegmentLocation: nil,
            selectedHighlightRangeOverride: nil,
            playbackHighlightRangeOverride: nil,
            activePlaybackCueIndex: nil,
            illegalMergeBoundaryLocation: nil,
            furiganaBySegmentLocation: furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
            isVisualEnhancementsEnabled: true,
            isRubySpacingEnabled: true,
            isColorAlternationEnabled: true,
            isHighlightUnknownEnabled: false,
            unknownSegmentLocations: [],
            changedSegmentLocations: [],
            changedReadingLocations: [],
            customEvenSegmentColorHex: "",
            customOddSegmentColorHex: "",
            debugFuriganaRects: debugFuriganaRects,
            debugHeadwordRects: debugHeadwordRects,
            debugHeadwordLineBands: debugHeadwordLineBands,
            debugFuriganaLineBands: debugFuriganaLineBands,
            debugBisectors: debugBisectors,
            debugEnvelopeRects: debugEnvelopeRects,
            externalContentOffsetY: 0,
            onScrollOffsetYChanged: { _ in },
            onSegmentTapped: { _, _, _ in },
            textSize: $textSize,
            lineSpacing: lineSpacing,
            kerning: kerning,
            furiganaGap: furiganaGap,
            isScrollEnabled: false
        )
    }
}
