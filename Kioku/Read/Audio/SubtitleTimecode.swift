import Foundation

// Shared millisecond ↔ timecode conversion for subtitle parsing/formatting. Both SRT
// ("HH:MM:SS,mmm") and ASS ("H:MM:SS.cc") timestamps decompose the same way — only the
// fractional separator (comma vs period) and width (milli- vs centi-second) differ, and
// padding the fraction to three digits handles both. Before this existed the same
// h*3_600_000 + m*60_000 + s*1_000 + frac arithmetic was typed out in SubtitleParser
// (format + parse) and ASSParser (parse).
nonisolated enum SubtitleTimecode {
    // Parses "H:MM:SS.fff" or "HH:MM:SS,fff" to milliseconds. Accepts comma or period as the
    // fractional separator and a centisecond (2-digit) or millisecond (3-digit) fraction.
    // Returns nil for malformed input so the caller can skip the row instead of crashing.
    static func parseToMilliseconds(_ raw: String) -> Int? {
        let normalized = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let colonParts = normalized.components(separatedBy: ":")
        guard colonParts.count == 3,
              let hours = Int(colonParts[0]),
              let minutes = Int(colonParts[1]) else {
            return nil
        }

        let secParts = colonParts[2].components(separatedBy: ".")
        guard let seconds = Int(secParts[0]) else { return nil }

        // Normalise the fractional part to exactly three digits (milliseconds): "5" → "500",
        // "50" (centiseconds) → "500", "500" → "500", "5009" → "500".
        let fracStr = secParts.count > 1 ? secParts[1] : "0"
        let milliseconds = Int((fracStr + "000").prefix(3)) ?? 0

        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds
    }

    // Formats a millisecond offset as the SRT "HH:MM:SS,mmm" timecode string.
    static func formatSRT(_ ms: Int) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
