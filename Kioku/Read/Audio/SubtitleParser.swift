import Foundation

// Parses SRT subtitle file content into an ordered list of SubtitleCues and assembles note content.
enum SubtitleParser {
    // Parses an SRT string into cues. Offsets into note content are not stored here;
    // call resolveHighlightRanges(for:in:) separately at playback time.
    static func parse(_ srtContent: String) -> [SubtitleCue] {
        // Split on blank lines that separate cue blocks.
        let blocks = srtContent.components(separatedBy: "\n\n")
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
    // Sequential search means duplicate cue texts are matched in order, not always to the first
    // occurrence, so a cue that reuses an earlier line highlights the correct second instance.
    // Returns nil for any cue whose text cannot be found (e.g. after the note was heavily edited).
    static func resolveHighlightRanges(for cues: [SubtitleCue], in noteText: String) -> [NSRange?] {
        var searchStart = noteText.startIndex
        return cues.map { cue in
            guard let range = noteText.range(of: cue.text, range: searchStart..<noteText.endIndex) else {
                return nil
            }
            searchStart = range.upperBound
            return NSRange(range, in: noteText)
        }
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
