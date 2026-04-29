// SRTWriter.swift
// Converts AlignmentResult into a valid SRT subtitle string.
// Format matches stable-ts to_srt_vtt(segment_level=True, word_level=False).

import Foundation

public struct SRTWriter {

    /// Returns the full SRT file content as a String.
    public static func write(_ result: AlignmentResult) -> String {
        result.lines.enumerated().map { index, line in
            "\(index + 1)\n\(timestamp(line.start)) --> \(timestamp(line.end))\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    public static func write(_ result: AlignmentResult, to url: URL) throws {
        try write(result).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Converts seconds to SRT timestamp format HH:MM:SS,mmm.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let ms = Int((total * 1000).rounded()) % 1000
        let s  = Int(total) % 60
        let m  = (Int(total) / 60) % 60
        let h  = Int(total) / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
