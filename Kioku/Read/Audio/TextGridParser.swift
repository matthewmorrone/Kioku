import Foundation

// Parses Praat short-form TextGrid text into the unified TimedTextDocument.
// Long-form (xmin = / text = labels) is intentionally out of scope for v1.
nonisolated enum TextGridParser {

    enum ParseError: Error, Equatable {
        case malformed(String)
    }

    // Parses a short-form Praat TextGrid string into a TimedTextDocument.
    // Times are converted from seconds to integer milliseconds at parse time.
    // Throws ParseError.malformed for long-form input or unrecoverable structural problems.
    static func parse(_ content: String) throws -> TimedTextDocument {
        if content.contains("item []:") || content.range(of: #"\bxmin\s*="#, options: .regularExpression) != nil {
            throw ParseError.malformed("Long-form TextGrid is not supported in v1; convert to short-form.")
        }

        var tokens = tokenize(content)[...]
        // Praat headers ("File type = ...", "Object class = ...") tokenize as a mix of barewords
        // and strings. Drop leading non-number tokens until the first numeric token (file xmin).
        while let first = tokens.first {
            if case .number = first { break }
            tokens = tokens.dropFirst()
        }

        guard case .number = tokens.first else {
            throw ParseError.malformed("Missing file xmin.")
        }
        _ = tokens.popFirst()
        guard case let .number(fileXmax)? = tokens.popFirst() else {
            throw ParseError.malformed("Missing file xmax.")
        }
        if case .bareword("exists")? = tokens.first {
            tokens = tokens.dropFirst()
        }
        guard case let .number(tierCountValue)? = tokens.popFirst() else {
            throw ParseError.malformed("Missing tier count.")
        }
        let tierCount = Int(tierCountValue)

        var tiers: [TimedTier] = []
        for _ in 0..<tierCount {
            guard case let .string(tierKind)? = tokens.popFirst() else {
                throw ParseError.malformed("Missing tier kind.")
            }
            guard case let .string(tierName)? = tokens.popFirst() else {
                throw ParseError.malformed("Missing tier name for tier of kind \(tierKind).")
            }
            guard case .number = tokens.popFirst(),
                  case .number = tokens.popFirst() else {
                throw ParseError.malformed("Missing tier xmin/xmax for tier \(tierName).")
            }
            guard case let .number(intervalCountValue)? = tokens.popFirst() else {
                throw ParseError.malformed("Missing interval count for tier \(tierName).")
            }
            let intervalCount = Int(intervalCountValue)

            var spans: [TimedSpan] = []
            if tierKind == "IntervalTier" {
                for _ in 0..<intervalCount {
                    guard case let .number(xmin)? = tokens.popFirst(),
                          case let .number(xmax)? = tokens.popFirst(),
                          case let .string(label)? = tokens.popFirst() else {
                        throw ParseError.malformed("Truncated interval in tier \(tierName).")
                    }
                    spans.append(
                        TimedSpan(
                            startMs: Int((xmin * 1000).rounded()),
                            endMs: Int((xmax * 1000).rounded()),
                            text: label
                        )
                    )
                }
            } else {
                // PointTier / TextTier — parse structurally, model as tier with zero spans.
                for _ in 0..<intervalCount {
                    guard tokens.popFirst() != nil, tokens.popFirst() != nil else {
                        throw ParseError.malformed("Truncated point in tier \(tierName).")
                    }
                }
            }

            tiers.append(TimedTier(name: tierName, spans: spans))
        }

        return TimedTextDocument(
            durationMs: Int((fileXmax * 1000).rounded()),
            tiers: tiers
        )
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case string(String)
        case bareword(String)
    }

    // Splits the file into a stream of number / quoted-string / bareword tokens so the parser can
    // consume them in expected order without re-scanning the source. Comments (lines starting with `!`)
    // and whitespace are dropped. Inside a quoted string, `""` escapes a literal `"`.
    private static func tokenize(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var iter = source.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        // Returns the next scalar, draining the one-slot push-back buffer first.
        func nextScalar() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iter.next()
        }
        // Stores one scalar back into the buffer so the next nextScalar() returns it.
        func pushBack(_ s: Unicode.Scalar) { pending = s }

        while let scalar = nextScalar() {
            if scalar.properties.isWhitespace || scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == " " {
                continue
            }
            if scalar == "!" {
                while let s = nextScalar(), s != "\n" {}
                continue
            }
            if scalar == "\"" {
                var accum = ""
                while let s = nextScalar() {
                    if s == "\"" {
                        if let peek = nextScalar() {
                            if peek == "\"" {
                                accum.unicodeScalars.append(s)
                            } else {
                                pushBack(peek)
                                break
                            }
                        } else {
                            break
                        }
                    } else {
                        accum.unicodeScalars.append(s)
                    }
                }
                tokens.append(.string(accum))
                continue
            }
            if scalar == "<" {
                var accum = ""
                while let s = nextScalar(), s != ">" {
                    accum.unicodeScalars.append(s)
                }
                tokens.append(.bareword(accum))
                continue
            }
            var accum = ""
            accum.unicodeScalars.append(scalar)
            while let s = nextScalar() {
                if s.properties.isWhitespace || s == "\n" || s == "\r" || s == "\t" || s == " " {
                    break
                }
                accum.unicodeScalars.append(s)
            }
            if let value = Double(accum) {
                tokens.append(.number(value))
            } else {
                tokens.append(.bareword(accum))
            }
        }

        return tokens
    }
}
