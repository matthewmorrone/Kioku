// SRTWriter.swift
// Converts a sequence of AlignedLines into a valid SRT subtitle string.
// Format matches stable-ts to_srt_vtt(segment_level=True, word_level=False):
// one numbered block per input line with HH:MM:SS,mmm timestamps.

import Foundation

// Produces SRT text from the output of LineAligner — one entry per aligned line.
enum SRTWriter {

    // Returns the full SRT file content as a String — one entry per AlignedLine.
    static func write(_ lines: [AlignedLine]) -> String {
        lines.enumerated().map { index, line in
            "\(index + 1)\n\(timestamp(line.start)) --> \(timestamp(line.end))\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    // Converts seconds to SRT timestamp format HH:MM:SS,mmm.
    // Uses comma as decimal separator per the SRT spec (not a period).
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let ms = Int((total * 1000).rounded()) % 1000
        let s  = Int(total) % 60
        let m  = (Int(total) / 60) % 60
        let h  = Int(total) / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
