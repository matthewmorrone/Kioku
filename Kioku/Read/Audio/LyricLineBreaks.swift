import Foundation

// One spelling of a line break for lyric line splitting. Pasted lyrics often separate a verse's
// lines with U+2028 (line separator) or U+2029 (paragraph separator), which the note shows as
// line breaks; the aligner and the song breakdown split on "\n", so without this a whole verse
// becomes one cue and one breakdown line.
enum LyricLineBreaks {
    // Returns `text` with every line break (\r\n, \r, U+2028, U+2029) written as "\n".
    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}
