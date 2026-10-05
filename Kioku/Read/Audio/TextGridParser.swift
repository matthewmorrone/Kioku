import Foundation

// Failure case surfaced by TextGridParser.parse.
enum TextGridParseError: Error, Equatable {
    case malformed(String)
}

// One lexical token produced by TextGridParser's tokenizer.
private enum TextGridToken: Equatable {
    case number(Double)
    case string(String)
    case bareword(String)
}

// Parses Praat short-form TextGrid text into the unified TimedTextDocument.
// Long-form (xmin = / text = labels) is intentionally out of scope for v1.
nonisolated enum TextGridParser {

    // Parses a short-form Praat TextGrid string into a TimedTextDocument.
    // Times are converted from seconds to integer milliseconds at parse time.
    // Throws TextGridParseError.malformed for long-form input or unrecoverable structural problems.
    static func parse(_ content: String) throws -> TimedTextDocument {
        if content.contains("item []:") || content.range(of: #"\bxmin\s*="#, options: .regularExpression) != nil {
            throw TextGridParseError.malformed("Long-form TextGrid is not supported in v1; convert to short-form.")
        }

        var tokens = tokenize(content)[...]
        // Praat headers ("File type = ...", "Object class = ...") tokenize as a mix of barewords
        // and strings. Drop leading non-number tokens until the first numeric token (file xmin).
        while let first = tokens.first {
            if case .number = first { break }
            tokens = tokens.dropFirst()
        }

        guard case .number = tokens.first else {
            throw TextGridParseError.malformed("Missing file xmin.")
        }
        _ = tokens.popFirst()
        guard case let .number(fileXmax)? = tokens.popFirst() else {
            throw TextGridParseError.malformed("Missing file xmax.")
        }
        if case .bareword("exists")? = tokens.first {
            tokens = tokens.dropFirst()
        }
        guard case let .number(tierCountValue)? = tokens.popFirst() else {
            throw TextGridParseError.malformed("Missing tier count.")
        }
        guard let tierCount = count(from: tierCountValue, limit: maxTierCount) else {
            throw TextGridParseError.malformed("Invalid tier count.")
        }

        var tiers: [TimedTier] = []
        for _ in 0..<tierCount {
            guard case let .string(tierKind)? = tokens.popFirst() else {
                throw TextGridParseError.malformed("Missing tier kind.")
            }
            guard case let .string(tierName)? = tokens.popFirst() else {
                throw TextGridParseError.malformed("Missing tier name for tier of kind \(tierKind).")
            }
            guard case .number = tokens.popFirst(),
                  case .number = tokens.popFirst() else {
                throw TextGridParseError.malformed("Missing tier xmin/xmax for tier \(tierName).")
            }
            guard case let .number(intervalCountValue)? = tokens.popFirst() else {
                throw TextGridParseError.malformed("Missing interval count for tier \(tierName).")
            }
            guard let intervalCount = count(from: intervalCountValue, limit: maxIntervalCount) else {
                throw TextGridParseError.malformed("Invalid interval count for tier \(tierName).")
            }

            var spans: [TimedSpan] = []
            if tierKind == "IntervalTier" {
                for _ in 0..<intervalCount {
                    guard case let .number(xmin)? = tokens.popFirst(),
                          case let .number(xmax)? = tokens.popFirst(),
                          case let .string(label)? = tokens.popFirst() else {
                        throw TextGridParseError.malformed("Truncated interval in tier \(tierName).")
                    }
                    guard let startMs = milliseconds(fromSeconds: xmin),
                          let endMs = milliseconds(fromSeconds: xmax) else {
                        throw TextGridParseError.malformed("Invalid interval time in tier \(tierName).")
                    }
                    spans.append(TimedSpan(startMs: startMs, endMs: endMs, text: label))
                }
            } else {
                // PointTier / TextTier — parse structurally, model as tier with zero spans.
                for _ in 0..<intervalCount {
                    guard tokens.popFirst() != nil, tokens.popFirst() != nil else {
                        throw TextGridParseError.malformed("Truncated point in tier \(tierName).")
                    }
                }
            }

            tiers.append(TimedTier(name: tierName, spans: spans))
        }

        guard let durationMs = milliseconds(fromSeconds: fileXmax) else {
            throw TextGridParseError.malformed("Invalid file xmax.")
        }
        return TimedTextDocument(durationMs: durationMs, tiers: tiers)
    }

    // Ceilings on declared counts. Real alignment TextGrids have a handful of tiers and at most a
    // few thousand intervals; the counts drive loops, so an absurd value must be rejected rather
    // than iterated. Each interval needs three tokens, so truncation is caught well before these.
    private static let maxTierCount = 1_000
    private static let maxIntervalCount = 1_000_000
    // Twenty-four hours: far beyond any song or episode, small enough that ms arithmetic can't overflow.
    private static let maxSeconds = 86_400.0

    // Converts a parsed count to Int only when it is a finite, non-negative whole number within
    // `limit`; Int(Double) traps on NaN, infinity and out-of-range values from a malformed file.
    private static func count(from value: Double, limit: Int) -> Int? {
        guard value.isFinite, value >= 0, value <= Double(limit), value.rounded() == value else { return nil }
        return Int(value)
    }

    // Converts seconds to integer milliseconds, nil for non-finite, negative or implausibly large
    // times so a malformed file fails to parse instead of trapping in Int(Double).
    private static func milliseconds(fromSeconds seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, seconds <= maxSeconds else { return nil }
        return Int((seconds * 1000).rounded())
    }

    // MARK: - Tokenizer

    // Splits the file into a stream of number / quoted-string / bareword tokens so the parser can
    // consume them in expected order without re-scanning the source. Comments (lines starting with `!`)
    // and whitespace are dropped. Inside a quoted string, `""` escapes a literal `"`.
    private static func tokenize(_ source: String) -> [TextGridToken] {
        var tokens: [TextGridToken] = []
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
