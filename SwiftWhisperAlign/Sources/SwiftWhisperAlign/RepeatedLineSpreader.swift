// RepeatedLineSpreader.swift
//
// Identical lines sung back to back (ムーンハートシークエンス's four セーラームーン chants) give the
// Viterbi nothing to tell them apart, and when the model can't hear some of the repeats it stacks
// two copies into the one phrase it can hear and leaves a later phrase empty. A run of identical
// consecutive lines that shares a sung phrase is re-spread one line per phrase, in order, across
// the phrases between the run's first line and the next different line — only when there are
// enough phrases for every copy. A moved copy's checkpoints were placed where it had been stacked,
// so they mean nothing in its new phrase; they're spaced evenly across its new span, one step per
// span (a span is a kana or a kanji run, so roughly a mora each).

import Foundation

enum RepeatedLineSpreader {
    // The gap left before the next line when a line's end runs up to it.
    static let bridgeMargin = 0.05
    // How far past its phrase's end a spread line's highlight may run.
    static let endAllowance = 0.2

    // `lines` / `lineTokens` with every stacked run of identical lines spread across `regions`
    // (sung phrases, seconds, ascending).
    static func spread(
        lines: [AlignedLine], lineTokens: [[AlignedToken]], regions: [(start: Double, end: Double)], durationSec: Double
    ) -> (lines: [AlignedLine], lineTokens: [[AlignedToken]]) {
        var lines = lines, tokens = lineTokens
        func region(of t: Double) -> Int? { regions.lastIndex { $0.start <= t + 0.5 } }
        var i = 0
        while i < lines.count {
            var j = i
            while j + 1 < lines.count, lines[j + 1].text == lines[i].text { j += 1 }
            defer { i = j + 1 }
            guard j > i, let first = region(of: lines[i].start) else { continue }
            let owners = (i...j).compactMap { region(of: lines[$0].start) }
            // Already one per phrase: nothing stacked.
            guard Set(owners).count < owners.count else { continue }
            let nextStart = j + 1 < lines.count ? lines[j + 1].start : durationSec
            let phrases = Array(regions[first...].prefix { $0.start < nextStart })
            guard phrases.count >= j - i + 1 else { continue }
            // Each copy after the first starts where its phrase starts.
            var moved = Set<Int>()
            for k in 1...(j - i) {
                let line = i + k
                let delta = max(phrases[k].start, lines[line - 1].start + 0.3) - lines[line].start
                guard delta > 0 else { continue }
                lines[line] = AlignedLine(text: lines[line].text, start: lines[line].start + delta, end: lines[line].end + delta)
                moved.insert(line)
            }
            // Each copy ends with its phrase (a breath past it), never after the next line starts.
            for k in 0...(j - i) {
                let line = i + k
                let next = line + 1 < lines.count ? lines[line + 1].start : durationSec
                let end = max(lines[line].start + 0.3, min(phrases[k].end + endAllowance, next - bridgeMargin))
                lines[line] = AlignedLine(text: lines[line].text, start: lines[line].start, end: end)
                if moved.contains(line) {
                    let step = (end - lines[line].start) / Double(max(1, tokens[line].count))
                    tokens[line] = tokens[line].enumerated().map { n, t in
                        AlignedToken(start: lines[line].start + Double(n) * step, charOffsetUTF16: t.charOffsetUTF16, charLengthUTF16: t.charLengthUTF16)
                    }
                } else {
                    tokens[line] = tokens[line].map { AlignedToken(start: min($0.start, end), charOffsetUTF16: $0.charOffsetUTF16, charLengthUTF16: $0.charLengthUTF16) }
                }
            }
        }
        return (lines, tokens)
    }
}
