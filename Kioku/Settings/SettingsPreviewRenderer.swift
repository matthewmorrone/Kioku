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

        // Fill gaps between furigana words with non-furigana segments.
        var result: [Range<String.Index>] = []
        var cursor = 0
        for r in ranges {
            if r.location > cursor {
                let gapNS = NSRange(location: cursor, length: r.location - cursor)
                if let gapRange = Range(gapNS, in: text) {
                    result.append(gapRange)
                }
            }
            let wordNS = NSRange(location: r.location, length: r.length)
            if let wordRange = Range(wordNS, in: text) {
                result.append(wordRange)
            }
            cursor = r.location + r.length
        }
        if cursor < nsText.length {
            let tailNS = NSRange(location: cursor, length: nsText.length - cursor)
            if let tailRange = Range(tailNS, in: text) {
                result.append(tailRange)
            }
        }
        return result
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
