import UIKit
import CoreText

// Builds NSAttributedString with CTRubyAnnotation applied per kanji run.
// Shared by FuriganaLabel (SwiftUI) and SegmentLookupSheet (UIKit).
enum FuriganaAttributedString {

    // Builds an attributed string with per-kanji-run furigana for the given surface and reading.
    // Falls back to plain text when run-reading projection fails so okurigana never ends up inside ruby.
    static func build(surface: String, reading: String, font: UIFont) -> NSAttributedString {
        let runs = kanjiRuns(in: surface)
        guard !runs.isEmpty else {
            return NSAttributedString(string: surface, attributes: [.font: font])
        }

        if let runReadings = normalizedRunReadings(surface: surface, reading: reading, runs: runs),
           runReadings.count == runs.count {
            return buildPerRunAttributedString(surface: surface, runs: runs, runReadings: runReadings, font: font)
        }

        // A whole-surface ruby fallback puts trailing kana inside the annotation, which is worse than
        // showing no furigana for that token.
        return NSAttributedString(string: surface, attributes: [.font: font])
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

    // Normalizes a segment reading into one per kanji run, trimming redundant okurigana when a
    // single-run surface was stored as one mixed annotation (for example 抱かれ + だかれ -> だ).
    static func normalizedRunReadings(
        surface: String,
        reading: String,
        runs: [(start: Int, end: Int)]? = nil
    ) -> [String]? {
        let runs = runs ?? kanjiRuns(in: surface)
        guard runs.isEmpty == false else { return nil }

        if let projected = projectRunReadings(surface: surface, reading: reading, runs: runs),
           projected.count == runs.count {
            return projected
        }

        guard runs.count == 1,
              let isolatedReading = isolatedRunReading(surface: surface, reading: reading, run: runs[0]) else {
            return nil
        }

        return [isolatedReading]
    }

    // Returns the display reading for a single applied furigana annotation range.
    // Multi-run mixed surfaces are rejected because one overlay label cannot represent them safely.
    static func normalizedDisplayReading(surface: String, reading: String) -> String? {
        let runs = kanjiRuns(in: surface)
        guard runs.count == 1,
              let runReadings = normalizedRunReadings(surface: surface, reading: reading, runs: runs),
              runReadings.count == 1 else {
            return nil
        }

        return runReadings[0]
    }

    // Extracts the reading for a single kanji run by removing matching kana affixes from the full
    // segment reading using the same phonetic normalization used elsewhere in furigana alignment.
    private static func isolatedRunReading(
        surface: String,
        reading: String,
        run: (start: Int, end: Int)
    ) -> String? {
        let characters = Array(surface)
        let prefixSurface = run.start > 0 ? String(characters[..<run.start]) : ""
        let suffixSurface = run.end < characters.count ? String(characters[run.end..<characters.count]) : ""
        var trimmedReading = reading

        if !prefixSurface.isEmpty {
            guard hasPhoneticPrefix(trimmedReading, matching: prefixSurface) else {
                return nil
            }
            trimmedReading = String(trimmedReading.dropFirst(prefixSurface.count))
        }

        if !suffixSurface.isEmpty {
            guard hasPhoneticSuffix(trimmedReading, matching: suffixSurface) else {
                return nil
            }
            trimmedReading = String(trimmedReading.dropLast(suffixSurface.count))
        }

        let runSurface = String(characters[run.start..<run.end])
        guard !trimmedReading.isEmpty, trimmedReading != runSurface else {
            return nil
        }

        return trimmedReading
    }

    // Checks whether a reading starts with the same phonetic syllables as a kanji run prefix so prefix kana can be excluded from furigana.
    private static func hasPhoneticPrefix(_ reading: String, matching surfacePrefix: String) -> Bool {
        guard reading.count >= surfacePrefix.count else {
            return false
        }

        let readingPrefix = String(reading.prefix(surfacePrefix.count))
        return KanaNormalizer.normalizeForFuriganaAlignment(readingPrefix) == KanaNormalizer.normalizeForFuriganaAlignment(surfacePrefix)
    }

    // Checks whether a reading ends with the same phonetic syllables as a kanji run suffix so trailing kana can be excluded from furigana.
    private static func hasPhoneticSuffix(_ reading: String, matching surfaceSuffix: String) -> Bool {
        guard reading.count >= surfaceSuffix.count else {
            return false
        }

        let readingSuffix = String(reading.suffix(surfaceSuffix.count))
        return KanaNormalizer.normalizeForFuriganaAlignment(readingSuffix) == KanaNormalizer.normalizeForFuriganaAlignment(surfaceSuffix)
    }
}
