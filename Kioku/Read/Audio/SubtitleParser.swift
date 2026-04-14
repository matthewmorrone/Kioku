import Foundation

// Parses SRT subtitle file content into an ordered list of SubtitleCues and assembles note content.
enum SubtitleParser {
    // Parses an SRT string into cues. Offsets into note content are not stored here;
    // call resolveHighlightRanges(for:in:) separately at playback time.
    static func parse(_ srtContent: String) -> [SubtitleCue] {
        let normalizedContent = srtContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Split on blank lines that separate cue blocks.
        let blocks = normalizedContent.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []

        for block in blocks {
            let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBlock.isEmpty == false else { continue }

            let lines = trimmedBlock.components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }

            guard let index = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let (startMs, endMs) = parseTimecodeRow(lines[1]) else { continue }

            let text = lines[2...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }

            cues.append(SubtitleCue(index: index, startMs: startMs, endMs: endMs, text: text))
        }

        return cues
    }

    // Joins all cue texts with newlines to form the note body.
    static func assembleNoteContent(from cues: [SubtitleCue]) -> String {
        cues.map(\.text).joined(separator: "\n")
    }

    // Resolves each cue's text to an NSRange within noteText by searching sequentially.
    // Three-tier matching: exact substring → normalized line text → positional (next note line).
    // Positional fallback ensures cues always align even when text differs (e.g. kana vs kanji).
    // Returns nil only for non-speech cues like ♪ that have no corresponding note line.
    static func resolveHighlightRanges(for cues: [SubtitleCue], in noteText: String) -> [NSRange?] {
        var searchStart = noteText.startIndex
        var lineSearchIndex = 0
        let noteLineRanges = extractNoteLineRanges(from: noteText)
        return cues.map { cue in
            // Non-speech cues (♪) have no note line — skip.
            if isNonSpeechCue(cue.text) {
                return nil
            }

            // Tier 1: exact substring match.
            if let range = noteText.range(of: cue.text, range: searchStart..<noteText.endIndex) {
                searchStart = range.upperBound
                if let matchedLineIndex = noteLineRanges.firstIndex(where: { NSIntersectionRange($0, NSRange(range, in: noteText)).length > 0 }) {
                    lineSearchIndex = matchedLineIndex + 1
                }
                return NSRange(range, in: noteText)
            }

            // Tier 2: normalized line text comparison.
            if let fallbackRange = resolveLineBasedHighlightRange(
                for: cue,
                in: noteText,
                lineRanges: noteLineRanges,
                lineSearchIndex: &lineSearchIndex
            ) {
                if let fallbackSwiftRange = Range(fallbackRange, in: noteText) {
                    searchStart = fallbackSwiftRange.upperBound
                }
                return fallbackRange
            }

            // Tier 3: positional fallback — assign to the next non-blank unmatched note line.
            while lineSearchIndex < noteLineRanges.count {
                let positionalRange = noteLineRanges[lineSearchIndex]
                lineSearchIndex += 1
                guard let swiftRange = Range(positionalRange, in: noteText) else { continue }
                let lineText = noteText[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard lineText.isEmpty == false else { continue }
                searchStart = swiftRange.upperBound
                return positionalRange
            }

            return nil
        }
    }

    // Returns true for cues that represent instrumental/non-speech sections.
    static func isNonSpeechCue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "♪" || trimmed == "♫" || trimmed.isEmpty
    }

    // Finds the note line that matches a cue's text so the cue can be highlighted during playback.
    private static func resolveLineBasedHighlightRange(
        for cue: SubtitleCue,
        in noteText: String,
        lineRanges: [NSRange],
        lineSearchIndex: inout Int
    ) -> NSRange? {
        let normalizedCueText = normalizedSubtitleMatchText(cue.text)
        guard normalizedCueText.isEmpty == false else {
            return nil
        }

        for lineIndex in lineSearchIndex..<lineRanges.count {
            let lineRange = lineRanges[lineIndex]
            guard let swiftRange = Range(lineRange, in: noteText) else {
                continue
            }

            let lineText = String(noteText[swiftRange])
            guard normalizedSubtitleMatchText(lineText) == normalizedCueText else {
                continue
            }

            lineSearchIndex = lineIndex + 1
            return lineRange
        }

        return nil
    }

    // Pre-computes NSRanges for every line in the note so cue matching can walk them without re-scanning.
    private static func extractNoteLineRanges(from noteText: String) -> [NSRange] {
        let nsText = noteText as NSString
        var lineRanges: [NSRange] = []
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            lineRanges.append(substringRange)
        }
        return lineRanges
    }

    // Collapses whitespace and fullwidth spaces so cue text can be compared to note lines without formatting differences.
    private static func normalizedSubtitleMatchText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Reconstructs a well-formed SRT string from a cue list so the user can edit and re-import it.
    static func formatSRT(from cues: [SubtitleCue]) -> String {
        cues.map { cue in
            "\(cue.index)\n\(formatTimecode(cue.startMs)) --> \(formatTimecode(cue.endMs))\n\(cue.text)"
        }.joined(separator: "\n\n")
    }

    // Formats a millisecond offset as the SRT "HH:MM:SS,mmm" timecode string.
    private static func formatTimecode(_ ms: Int) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    // Parses "HH:MM:SS,mmm --> HH:MM:SS,mmm" into a (startMs, endMs) tuple.
    private static func parseTimecodeRow(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: " --> ")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (start, end)
    }

    // Converts "HH:MM:SS,mmm" (comma or period as fractional separator) to milliseconds.
    private static func parseTimestamp(_ raw: String) -> Int? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let colonParts = normalized.components(separatedBy: ":")
        guard colonParts.count == 3,
              let hours = Int(colonParts[0]),
              let minutes = Int(colonParts[1]) else {
            return nil
        }

        let secParts = colonParts[2].components(separatedBy: ".")
        guard let seconds = Int(secParts[0]) else { return nil }

        // Normalise fractional part to exactly three digits for milliseconds.
        let fracStr = secParts.count > 1 ? secParts[1] : "0"
        let paddedFrac = (fracStr + "000").prefix(3)
        let milliseconds = Int(paddedFrac) ?? 0

        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds
    }
}
