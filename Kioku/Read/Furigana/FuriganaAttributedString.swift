import UIKit
import CoreText

// Builds NSAttributedString with CTRubyAnnotation applied per kanji run.
// Shared by FuriganaLabel (SwiftUI) and SegmentLookupSheet (UIKit).
enum FuriganaAttributedString {

    // Builds an attributed string with per-kanji-run furigana for the given surface and reading.
    // Falls back to a full-surface ruby annotation when run-reading projection fails.
    static func build(surface: String, reading: String, font: UIFont) -> NSAttributedString {
        let runs = kanjiRuns(in: surface)
        guard !runs.isEmpty else {
            return NSAttributedString(string: surface, attributes: [.font: font])
        }

        if let runReadings = projectRunReadings(surface: surface, reading: reading, runs: runs),
           runReadings.count == runs.count {
            return buildPerRunAttributedString(surface: surface, runs: runs, runReadings: runReadings, font: font)
        }

        // Fall back: apply full reading as a single ruby span over the entire surface.
        return NSAttributedString(
            string: surface,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTRubyAnnotationAttributeName as String): makeRuby(reading),
            ]
        )
    }

    // Assembles the attributed string segment-by-segment, tagging only kanji runs with ruby.
    private static func buildPerRunAttributedString(
        surface: String,
        runs: [(start: Int, end: Int)],
        runReadings: [String],
        font: UIFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let characters = Array(surface)
        var cursor = 0

        for (i, run) in runs.enumerated() {
            if cursor < run.start {
                let kana = String(characters[cursor..<run.start])
                result.append(NSAttributedString(string: kana, attributes: [.font: font]))
            }

            let kanjiText = String(characters[run.start..<run.end])
            let runReading = runReadings[i]

            if !runReading.isEmpty, runReading != kanjiText {
                result.append(NSAttributedString(
                    string: kanjiText,
                    attributes: [
                        .font: font,
                        NSAttributedString.Key(kCTRubyAnnotationAttributeName as String): makeRuby(runReading),
                    ]
                ))
            } else {
                result.append(NSAttributedString(string: kanjiText, attributes: [.font: font]))
            }

            cursor = run.end
        }

        if cursor < characters.count {
            let kana = String(characters[cursor..<characters.count])
            result.append(NSAttributedString(string: kana, attributes: [.font: font]))
        }

        return result
    }

    // Creates a CTRubyAnnotation at 50% of the base font size, positioned above the base text.
    private static func makeRuby(_ text: String) -> CTRubyAnnotation {
        CTRubyAnnotationCreateWithAttributes(
            .center, .auto, .before,
            text as CFString,
            [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary
        )
    }

    // Detects contiguous kanji runs and returns character-index ranges within the surface.
    // Iteration marks (々) are treated as run continuations when they follow a kanji character.
    static func kanjiRuns(in text: String) -> [(start: Int, end: Int)] {
        let characters = Array(text)
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?

        for (index, character) in characters.enumerated() {
            let isKanji = ScriptClassifier.containsKanji(String(character))
            let isIterationMark = character.unicodeScalars.first?.value == 0x3005 // 々
            let continuesRun = isIterationMark && runStart != nil
            if isKanji || continuesRun {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append((start: start, end: index))
                runStart = nil
            }
        }

        if let start = runStart {
            runs.append((start: start, end: characters.count))
        }

        return runs
    }

    // Splits a full reading into per-kanji-run readings using okurigana as delimiters.
    // Returns nil when okurigana anchors cannot be matched so the caller falls back.
    static func projectRunReadings(surface: String, reading: String, runs: [(start: Int, end: Int)]? = nil) -> [String]? {
        let runs = runs ?? kanjiRuns(in: surface)
        guard !runs.isEmpty else { return nil }

        let chars = Array(surface)
        var cursor = reading.startIndex

        let prefix = runs[0].start > 0 ? String(chars[0..<runs[0].start]) : ""
        if !prefix.isEmpty, reading[cursor...].hasPrefix(prefix) {
            cursor = reading.index(cursor, offsetBy: prefix.count)
        }

        var result: [String] = []

        for i in runs.indices {
            let run = runs[i]
            let separator: String

            if i + 1 < runs.count {
                separator = String(chars[run.end..<runs[i + 1].start])
            } else {
                separator = run.end < chars.count ? String(chars[run.end...]) : ""
            }

            if separator.isEmpty {
                result.append(String(reading[cursor...]))
                cursor = reading.endIndex
                continue
            }

            if i == runs.count - 1 {
                guard String(reading[cursor...]).hasSuffix(separator) else { return nil }
                let tail = reading[cursor...]
                let endIdx = tail.index(tail.endIndex, offsetBy: -separator.count)
                result.append(String(tail[..<endIdx]))
                cursor = reading.endIndex
                continue
            }

            guard let sepRange = reading.range(of: separator, range: cursor..<reading.endIndex) else {
                return nil
            }

            result.append(String(reading[cursor..<sepRange.lowerBound]))
            cursor = sepRange.upperBound
        }

        if cursor < reading.endIndex, let last = result.indices.last {
            result[last] += String(reading[cursor...])
        }

        return result
    }
}
