import Foundation

// Splits a Japanese text string into sentence-level NSRange segments.
// Heuristic rules: split on 。！？ and on newlines; trims leading/trailing whitespace from each range.
// Deterministic for fixed input — no external dependencies.
enum SentenceRangeResolver {
    // Returns trimmed, non-empty NSRange values covering each sentence in the text.
    static func sentenceRanges(in text: NSString) -> [NSRange] {
        let n = text.length
        guard n > 0 else { return [] }

        var out: [NSRange] = []
        out.reserveCapacity(16)

        var start = 0
        var i = 0
        while i < n {
            let ch = text.character(at: i)
            if isNewline(ch) {
                let raw = NSRange(location: start, length: max(0, i - start))
                appendTrimmed(raw, in: text, to: &out)
                start = i + 1
                i += 1
                continue
            }
            if isTerminator(ch) {
                let raw = NSRange(location: start, length: max(0, (i + 1) - start))
                appendTrimmed(raw, in: text, to: &out)
                start = i + 1
                i += 1
                continue
            }
            i += 1
        }

        if start < n {
            appendTrimmed(NSRange(location: start, length: n - start), in: text, to: &out)
        }

        return out
    }

    // Returns true for Japanese and ASCII sentence-ending punctuation.
    private static func isTerminator(_ ch: unichar) -> Bool {
        switch ch {
        case 0x3002, 0xFF01, 0xFF1F, 0x0021, 0x003F: return true
        default: return false
        }
    }

    // Returns true for LF and CR newline characters.
    private static func isNewline(_ ch: unichar) -> Bool {
        ch == 0x000A || ch == 0x000D
    }

    // Returns true for ASCII space, tab, and full-width space.
    private static func isWhitespace(_ ch: unichar) -> Bool {
        ch == 0x0020 || ch == 0x0009 || ch == 0x3000
    }

    // Trims whitespace from both ends of a range and appends it only if non-empty.
    private static func appendTrimmed(_ range: NSRange, in text: NSString, to out: inout [NSRange]) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        let n = text.length
        guard range.location >= 0, NSMaxRange(range) <= n else { return }

        var left = range.location
        var rightExclusive = NSMaxRange(range)

        while left < rightExclusive {
            let ch = text.character(at: left)
            if isWhitespace(ch) || isNewline(ch) { left += 1 } else { break }
        }
        while rightExclusive > left {
            let ch = text.character(at: rightExclusive - 1)
            if isWhitespace(ch) || isNewline(ch) { rightExclusive -= 1 } else { break }
        }

        let finalLen = rightExclusive - left
        guard finalLen > 0 else { return }
        out.append(NSRange(location: left, length: finalLen))
    }
}
