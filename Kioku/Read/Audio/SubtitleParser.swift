import Foundation

// Parses SRT subtitle file content into an ordered list of SubtitleCues and assembles note content.
enum SubtitleParser {
    // Parses an SRT string and returns cues with UTF-16 offsets computed from the joined note text.
    static func parse(_ srtContent: String) -> [SubtitleCue] {
        // Split on blank lines that separate cue blocks.
        let blocks = srtContent.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var noteContent = ""

        for block in blocks {
            let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBlock.isEmpty == false else { continue }

            let lines = trimmedBlock.components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }

            guard let index = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let (startMs, endMs) = parseTimecodeRow(lines[1]) else { continue }

            let text = lines[2...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }

            // Accumulate note text with a newline separator between cues.
            let separator = noteContent.isEmpty ? "" : "\n"
            let utf16Start = (noteContent + separator).utf16.count
            noteContent += separator + text
            let utf16End = noteContent.utf16.count

            cues.append(SubtitleCue(
                index: index,
                startMs: startMs,
                endMs: endMs,
                text: text,
                utf16Start: utf16Start,
                utf16End: utf16End
            ))
        }

        return cues
    }

    // Joins all cue texts with newlines to form the note body.
    static func assembleNoteContent(from cues: [SubtitleCue]) -> String {
        cues.map(\.text).joined(separator: "\n")
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
