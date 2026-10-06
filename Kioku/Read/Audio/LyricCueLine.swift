import Foundation

// The line a timed cue shows on the system Now Playing card.
enum LyricCueLine {
    // The first line of a possibly multi-line cue, trimmed — the line being sung. The card shows one
    // line, so a cue that runs onto a second line shows only its first.
    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
}
