import CoreGraphics
import Foundation

// Minimal SVG path-data (`d` attribute) parser, scoped to what KanjiVG actually uses:
//   M / m   moveto (absolute / relative)
//   L / l   lineto
//   C / c   cubic bezier
//   S / s   smooth cubic bezier (reflects previous control point)
//   Z / z   closepath
// KanjiVG paths are almost entirely M followed by C/S sequences; the other commands appear
// rarely in the dataset. We deliberately don't implement quadratic, arc, or H/V shorthands —
// if KanjiVG ever ships those we'd parse them as no-ops and the stroke would render straight.
nonisolated enum SVGPathParser {
    // Parses a `d` string into a `CGPath`. Returns nil if the input is empty or malformed enough
    // that we couldn't anchor to a starting moveto.
    static func cgPath(from d: String) -> CGPath? {
        var tokens = Tokenizer(input: d)
        let path = CGMutablePath()

        var hasMoved = false
        var currentPoint: CGPoint = .zero
        var subpathStart: CGPoint = .zero
        // Tracks the previous cubic control point for the `S`/`s` smooth-cubic reflection.
        var lastControl: CGPoint? = nil

        while let command = tokens.nextCommand() {
            // SVG allows omitting repeated command letters between coordinate runs; we loop
            // pulling argument groups until the next token is another command letter.
            repeat {
                switch command {
                case "M", "m":
                    let x = tokens.readNumber() ?? 0
                    let y = tokens.readNumber() ?? 0
                    let p = (command == "M") ? CGPoint(x: x, y: y)
                                             : CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    path.move(to: p)
                    currentPoint = p
                    subpathStart = p
                    hasMoved = true
                    lastControl = nil
                case "L", "l":
                    let x = tokens.readNumber() ?? 0
                    let y = tokens.readNumber() ?? 0
                    let p = (command == "L") ? CGPoint(x: x, y: y)
                                             : CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    path.addLine(to: p)
                    currentPoint = p
                    lastControl = nil
                case "C", "c":
                    guard let x1 = tokens.readNumber(),
                          let y1 = tokens.readNumber(),
                          let x2 = tokens.readNumber(),
                          let y2 = tokens.readNumber(),
                          let x = tokens.readNumber(),
                          let y = tokens.readNumber() else { break }
                    let c1: CGPoint
                    let c2: CGPoint
                    let end: CGPoint
                    if command == "C" {
                        c1 = CGPoint(x: x1, y: y1)
                        c2 = CGPoint(x: x2, y: y2)
                        end = CGPoint(x: x, y: y)
                    } else {
                        c1 = CGPoint(x: currentPoint.x + x1, y: currentPoint.y + y1)
                        c2 = CGPoint(x: currentPoint.x + x2, y: currentPoint.y + y2)
                        end = CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    currentPoint = end
                    lastControl = c2
                case "S", "s":
                    guard let x2 = tokens.readNumber(),
                          let y2 = tokens.readNumber(),
                          let x = tokens.readNumber(),
                          let y = tokens.readNumber() else { break }
                    // First control = reflection of previous's second control around current
                    // point, falling back to current point when the previous command wasn't a C/S.
                    let c1: CGPoint
                    if let prev = lastControl {
                        c1 = CGPoint(x: 2 * currentPoint.x - prev.x, y: 2 * currentPoint.y - prev.y)
                    } else {
                        c1 = currentPoint
                    }
                    let c2: CGPoint
                    let end: CGPoint
                    if command == "S" {
                        c2 = CGPoint(x: x2, y: y2)
                        end = CGPoint(x: x, y: y)
                    } else {
                        c2 = CGPoint(x: currentPoint.x + x2, y: currentPoint.y + y2)
                        end = CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    }
                    path.addCurve(to: end, control1: c1, control2: c2)
                    currentPoint = end
                    lastControl = c2
                case "Z", "z":
                    path.closeSubpath()
                    currentPoint = subpathStart
                    lastControl = nil
                default:
                    // Unknown command — consume one number to avoid infinite loop, then bail.
                    _ = tokens.readNumber()
                }
            } while tokens.peekIsNumber()
        }

        return hasMoved ? path : nil
    }

    // Tokenizer is internal-but-small: walks the string consuming whitespace/comma separators
    // and recognizing single-letter commands vs. signed-decimal numbers.
    fileprivate struct Tokenizer {
        let chars: [Character]
        var index: Int = 0

        init(input: String) {
            self.chars = Array(input)
        }

        // Returns the next command letter (M/m/L/l/C/c/S/s/Z/z…) and advances past it.
        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter {
                index += 1
                return c
            }
            return nil
        }

        // Peeks past whitespace/commas and returns true if a number token starts at the cursor.
        mutating func peekIsNumber() -> Bool {
            skipSeparators()
            guard index < chars.count else { return false }
            let c = chars[index]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        // Reads a signed decimal number (including scientific notation forms KanjiVG never uses,
        // but cheap to support). Returns nil if the cursor isn't on a number.
        mutating func readNumber() -> Double? {
            skipSeparators()
            guard index < chars.count else { return nil }

            let start = index
            if chars[index] == "-" || chars[index] == "+" { index += 1 }
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                index += 1
            }
            // Optional exponent.
            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                index += 1
                if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
                while index < chars.count, chars[index].isNumber { index += 1 }
            }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }

        // Skips whitespace and comma separators between tokens.
        mutating func skipSeparators() {
            while index < chars.count {
                let c = chars[index]
                if c.isWhitespace || c == "," {
                    index += 1
                } else {
                    break
                }
            }
        }
    }
}
