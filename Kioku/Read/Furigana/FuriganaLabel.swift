import SwiftUI
import UIKit
import CoreText

// Renders a word surface with per-kanji-run furigana using Core Text ruby annotations.
// Kana portions of the surface are rendered plainly without any annotation.
// Only kanji runs receive ruby; okurigana delimit where each kanji run's reading ends.
struct FuriganaLabel: UIViewRepresentable {
    let surface: String
    let reading: String
    let font: UIFont

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.backgroundColor = .clear
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.font = font
        label.attributedText = buildAttributedString()
    }

    // Reports the label's natural size so SwiftUI can allocate the correct height.
    // Without this, fixedSize(vertical:) collapses UIViewRepresentable to zero height.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    // Builds NSAttributedString with CTRubyAnnotation applied only to kanji runs.
    // Falls back to a full-surface annotation when run-reading projection fails.
    private func buildAttributedString() -> NSAttributedString {
        let runs = kanjiRuns(in: surface)
        guard !runs.isEmpty else {
            return NSAttributedString(string: surface, attributes: [.font: font])
        }

        if let runReadings = projectRunReadings(surface: surface, reading: reading),
           runReadings.count == runs.count {
            return buildPerRunAttributedString(runs: runs, runReadings: runReadings)
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
    private func buildPerRunAttributedString(
        runs: [(start: Int, end: Int)],
        runReadings: [String]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let characters = Array(surface)
        var cursor = 0

        for (i, run) in runs.enumerated() {
            // Plain kana before this kanji run — no annotation.
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

        // Trailing kana after the last kanji run — no annotation.
        if cursor < characters.count {
            let kana = String(characters[cursor..<characters.count])
            result.append(NSAttributedString(string: kana, attributes: [.font: font]))
        }

        return result
    }

    // Creates a CTRubyAnnotation at 50% of the base font size, positioned above the base text.
    private func makeRuby(_ text: String) -> CTRubyAnnotation {
        CTRubyAnnotationCreateWithAttributes(
            .auto, .auto, .before,
            text as CFString,
            [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary
        )
    }

    // Detects contiguous kanji runs and returns character-index ranges within the surface.
    private func kanjiRuns(in text: String) -> [(start: Int, end: Int)] {
        let characters = Array(text)
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?

        for (index, character) in characters.enumerated() {
            if ScriptClassifier.containsKanji(String(character)) {
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
    private func projectRunReadings(surface: String, reading: String) -> [String]? {
        let runs = kanjiRuns(in: surface)
        guard !runs.isEmpty else { return nil }

        let chars = Array(surface)
        var cursor = reading.startIndex

        // Advance past kana prefix before the first kanji run.
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

            // For the last run, okurigana must match the end of the remaining reading.
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

        // Append any leftover reading onto the last run's result.
        if cursor < reading.endIndex, let last = result.indices.last {
            result[last] += String(reading[cursor...])
        }

        return result
    }
}
