import SwiftUI
import UIKit

// Renders the live typography preview in the Settings typography section using the same
// CoreText renderer (KiokuCoreTextRendererView) that powers the read tab, so what users see
// in Settings matches what they will see on the read page byte-for-byte.
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
    let debugBisectorHeadword: Bool
    let debugBisectorFurigana: Bool
    let debugEnvelopeRects: Bool
    let debugLeftInsetGuide: Bool

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

    // Computes per-kanji-run furigana entries from the word-level table so the renderer centers
    // each reading over only its kanji glyphs — not over trailing okurigana. This matches the
    // format produced by ReadView+Segmentation when applying reading overrides: each entry's key
    // is the UTF-16 location of the kanji run, and the stored length covers only the kanji portion.
    // Without this projection, a reading like "ふか" for the segment "深める" would be centered on
    // the segment midpoint and visually drift onto the kana okurigana.
    private var perRunFuriganaEntries: [(location: Int, length: Int, reading: String)] {
        let nsText = Self.previewText as NSString
        var entries: [(location: Int, length: Int, reading: String)] = []
        for (word, reading) in Self.furigana {
            let wordRange = nsText.range(of: word)
            guard wordRange.location != NSNotFound else { continue }
            let chars = Array(word)
            let runs = FuriganaAttributedString.kanjiRuns(in: word)
            guard runs.isEmpty == false,
                  let runReadings = FuriganaAttributedString.normalizedRunReadings(
                      surface: word, reading: reading, runs: runs
                  ),
                  runReadings.count == runs.count else { continue }
            for (index, run) in runs.enumerated() {
                let runReading = runReadings[index]
                let runSurface = String(chars[run.start..<run.end])
                guard runReading.isEmpty == false, runReading != runSurface else { continue }
                let prefixUTF16 = String(chars[..<run.start]).utf16.count
                let runLength = runSurface.utf16.count
                entries.append((
                    location: wordRange.location + prefixUTF16,
                    length: runLength,
                    reading: runReading
                ))
            }
        }
        return entries
    }

    // Maps kanji-run UTF-16 start locations to their readings.
    private var furiganaBySegmentLocation: [Int: String] {
        var map: [Int: String] = [:]
        for entry in perRunFuriganaEntries {
            map[entry.location] = entry.reading
        }
        return map
    }

    // Maps kanji-run UTF-16 start locations to the run's UTF-16 length.
    private var furiganaLengthBySegmentLocation: [Int: Int] {
        var map: [Int: Int] = [:]
        for entry in perRunFuriganaEntries {
            map[entry.location] = entry.length
        }
        return map
    }

    var body: some View {
        // Match the default segment colors ReadView uses when custom token colors are off,
        // so the preview reads identically to the read tab in the common case.
        let evenColor = UIColor { tc in tc.userInterfaceStyle == .dark ? .systemOrange : .systemRed }
        let oddColor = UIColor { tc in tc.userInterfaceStyle == .dark ? .systemCyan : .systemIndigo }
        KiokuCoreTextRendererView(
            text: Self.previewText,
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
            isFuriganaVisible: true,
            isVisualEnhancementsEnabled: true,
            isColorAlternationEnabled: true,
            textSize: $textSize,
            lineSpacing: lineSpacing,
            kerning: kerning,
            furiganaGap: CGFloat(furiganaGap),
            evenSegmentColor: evenColor,
            oddSegmentColor: oddColor,
            isLineWrappingEnabled: true,
            isRubySpacingEnabled: true,
            selectedHighlightRange: nil,
            playbackHighlightRange: nil,
            selectionHighlightColor: .clear,
            playbackHighlightColor: .clear,
            unknownSegmentLocations: [],
            isHighlightUnknownEnabled: false,
            unknownSegmentColor: .label,
            debugFlags: KiokuDebugOverlayView.Flags(
                headwordRects: debugHeadwordRects,
                furiganaRects: debugFuriganaRects,
                envelopeRects: debugEnvelopeRects,
                headwordBisectors: debugBisectorHeadword,
                furiganaBisectors: debugBisectorFurigana,
                headwordLineBands: debugHeadwordLineBands,
                furiganaLineBands: debugFuriganaLineBands,
                pixelRuler: false,
                leftInsetGuide: debugLeftInsetGuide
            ),
            illegalMergeLocation: nil,
            onSegmentTapped: { _, _ in },
            isScrollEnabled: false
        )
    }
}
