import UIKit

// Recolors each subtitle cue's TIMESTAMP line on a green→red continuum by how far its on-screen
// duration deviates from what its mora count predicts at the song's OWN typical pace. The model is
// the classic timing sanity check: expected_duration ≈ morae × seconds-per-mora. A line sung far
// faster than its morae allow (a "cram") trends red; a line held far longer than its morae justify
// (stretched across an instrumental gap) also trends red; believable lines stay green. Only the
// timing line is tinted — the lyric text keeps its normal color.
//
// Two deliberate simplifications keep this cheap enough to run on every keystroke inside the SRT text
// view, while staying meaningful:
//   • Mora count is a character-class ESTIMATE (kana = 1, small kana = 0, kanji ≈ 2), not a tokenizer
//     reading — exact morae would need the segmenter and would be far too slow live.
//   • The baseline is the cues' MEDIAN seconds-per-mora, i.e. the song's own tempo. Judging each line
//     against that median cancels out both the song's pace and the estimator's systematic bias, so the
//     heatmap is meaningful relative to the rest of the song even though the absolute mora count is rough.
enum SubtitleTimingHeatmap {

    // Rough mora count from raw text — no reading lookup. Kana count 1 (small kana combine → 0),
    // kanji are approximated at ~2 morae (typical on'yomi length), latin vowels count as morae.
    static func estimatedMorae(_ text: String) -> Double {
        var morae = 0.0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049,           // small ぁぃぅぇぉ
                 0x3083, 0x3085, 0x3087, 0x308E,                   // ゃ ゅ ょ ゎ
                 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9,           // small ァィゥェォ
                 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6:   // ャ ュ ョ ヮ ヵ ヶ
                break                                              // combines with the preceding kana
            case 0x3040...0x309F, 0x30A0...0x30FF:                 // hiragana / katakana (incl. っ ー ん)
                morae += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: // kanji ≈ 2 morae
                morae += 2
            case 0x41...0x5A, 0x61...0x7A:                         // latin: count vowels as morae
                if "aeiouAEIOU".unicodeScalars.contains(s) { morae += 1 }
            default:
                break
            }
        }
        return morae
    }

    // Foreground-color ranges (UTF-16, into `srt`) for each cue's TIMESTAMP line, tinted by timing
    // plausibility. Returns [] when nothing parses (e.g. the user is mid-edit and the SRT is
    // momentarily malformed).
    static func timestampColorRanges(forSRT srt: String) -> [(NSRange, UIColor)] {
        struct Cue { let tsRange: NSRange; let dur: Double; let morae: Double }

        let ns = srt as NSString
        let lines = srt.components(separatedBy: "\n")
        // UTF-16 start offset of each line (+1 per "\n" separator).
        var lineOffsets: [Int] = []
        var acc = 0
        for l in lines { lineOffsets.append(acc); acc += (l as NSString).length + 1 }

        var cues: [Cue] = []
        var i = 0
        while i < lines.count {
            guard let (start, end) = parseTimestampLine(lines[i]) else { i += 1; continue }
            let tsRange = NSRange(location: lineOffsets[i], length: (lines[i] as NSString).length)
            // Gather the following text lines (for the mora count), up to a blank line or the next cue.
            var j = i + 1
            var textStart = -1, textEnd = -1
            while j < lines.count {
                let t = lines[j]
                if t.trimmingCharacters(in: .whitespaces).isEmpty || parseTimestampLine(t) != nil { break }
                if textStart < 0 { textStart = lineOffsets[j] }
                textEnd = lineOffsets[j] + (t as NSString).length
                j += 1
            }
            let text = textStart >= 0 ? ns.substring(with: NSRange(location: textStart, length: textEnd - textStart)) : ""
            if text.isEmpty == false && SubtitleParser.isNonSpeechCue(text) == false {
                cues.append(Cue(tsRange: tsRange, dur: max(0, end - start), morae: estimatedMorae(text)))
            }
            i = max(j, i + 1)
        }

        // Baseline = median seconds-per-mora across the (rateable) cues = the song's own tempo.
        let rates = cues.filter { $0.morae >= 0.5 && $0.dur > 0 }.map { $0.dur / $0.morae }.sorted()
        guard rates.isEmpty == false else { return [] }
        let baseline = rates[rates.count / 2]
        guard baseline > 0 else { return [] }

        var out: [(NSRange, UIColor)] = []
        for c in cues where c.morae >= 0.5 && c.dur > 0 {
            // Deviation in log space (symmetric: 3× too fast and 3× too slow both saturate to red).
            let ratio = (c.dur / c.morae) / baseline
            let dev = min(1.0, abs(log(ratio)) / log(3.0))
            let hue = CGFloat(0.33 * (1 - dev))   // 0.33 green → 0.0 red, through orange
            out.append((c.tsRange, heatColor(hue: hue)))
        }
        return out
    }

    // Foreground heat color for a hue, kept readable on both light and dark editor backgrounds
    // (darker/denser in light mode, brighter in dark mode).
    private static func heatColor(hue: CGFloat) -> UIColor {
        UIColor { tc in
            let dark = tc.userInterfaceStyle == .dark
            return UIColor(hue: hue, saturation: 0.9, brightness: dark ? 0.95 : 0.62, alpha: 1.0)
        }
    }

    // Parses "HH:MM:SS,mmm --> HH:MM:SS,mmm" → (startSeconds, endSeconds); nil if the line isn't one.
    private static func parseTimestampLine(_ line: String) -> (Double, Double)? {
        guard line.contains("-->") else { return nil }
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let a = parseTimestamp(parts[0]), let b = parseTimestamp(parts[1]) else { return nil }
        return (a, b)
    }

    // Parses a single "HH:MM:SS,mmm" (or ".mmm") timestamp into seconds; nil if malformed.
    private static func parseTimestamp(_ s: String) -> Double? {
        let hms = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".", with: ",")
            .components(separatedBy: ":")
        guard hms.count == 3 else { return nil }
        let secMs = hms[2].components(separatedBy: ",")
        guard secMs.count == 2,
              let h = Double(hms[0]), let m = Double(hms[1]),
              let sec = Double(secMs[0]), let ms = Double(secMs[1]) else { return nil }
        return h * 3600 + m * 60 + sec + ms / 1000
    }
}
