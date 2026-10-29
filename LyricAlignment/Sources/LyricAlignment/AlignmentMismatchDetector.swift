// AlignmentMismatchDetector.swift
//
// The aligner keeps the note's line order and places every line, so a note that doesn't match the
// recording (lines missing, lines in another order) still comes out fully timed, just wrong. Two
// signs of that are read off the finished alignment: singing the vocal stem has where no line was
// placed, and a line spread over far more time than its syllables can fill. Neither needs another
// model pass; both are deterministic for a fixed alignment and stem.

import Foundation

enum AlignmentMismatchDetector {
    // The least unbroken singing (seconds, inside one sung region) a stretch with no line must hold
    // before it counts. Backing vocals and ad-libs in an interlude stay under it, and so do the held
    // notes trailing into an interlude and leading out of it: those are separate regions, never
    // added together (a 4 s interlude with 2.6 s and 3.4 s of held notes either side is fine).
    static let unmatchedSingingMinSec = 5.0
    // …and the model must hear words in it: at least this share of its frames carry this much
    // letter probability in the stem. Wordless vocalising has the energy but not the words (乙女の
    // ススメ's 1:21–1:26 is 2% of frames; its sung gaps 11–13%).
    static let heardFrameShare = 0.05
    static let heardFrameMass: Float = 0.5
    // A line counts as stretched only when its words, first to last, take this long overall (the
    // line's own end is bridged to the next line, so a held last note isn't a stretch)…
    static let stretchedLineMinSec = 8.0
    // …and this slow per mora (sung lines run about 0.2–0.4 s a mora; a held final note adds a few
    // seconds to one line, not a second to every mora).
    static let stretchedSecPerMora = 0.8

    // Mismatches in `lines` and `lineTokens` (the aligner's timings) against `regions` (the sung
    // regions the alignment was pinned to), in time order. `romanization` gives each line's mora count.
    // `stem` is the stem's emission matrix before the interludes were pinned to blank.
    static func detect(
        lines: [AlignedLine], lineTokens: [[AlignedToken]], romanization: [[RomanizedSpan]],
        regions: [(start: Double, end: Double)], stem: CTCEmissions.Matrix?, durationSec: Double
    ) -> [AlignmentMismatch] {
        var found: [AlignmentMismatch] = []

        // Unmatched singing: the sung time inside each stretch no line covers.
        // Each stretch ends where line `next` starts (nil: the song's end).
        var cursor = 0.0
        let bounds: [(next: Int?, start: Double, end: Double)] =
            lines.enumerated().map { ($0.offset, $0.element.start, $0.element.end) } + [(nil, durationSec, durationSec)]
        for (next, start, end) in bounds {
            if start > cursor, let sung = longestSungRun(from: cursor, to: start, regions: regions),
               sung.end - sung.start >= unmatchedSingingMinSec,
               stem.map({ heardShare(in: $0, from: sung.start, to: sung.end) >= heardFrameShare }) ?? true {
                found.append(AlignmentMismatch(kind: .unmatchedSinging, start: sung.start, end: sung.end, lineIndex: next))
            }
            cursor = max(cursor, end)
        }

        // Stretched lines: words spread long overall and slow per mora.
        for (i, line) in lines.enumerated() where i < romanization.count && i < lineTokens.count {
            // A word CTC parked after an interlude keeps its time past the line's end; it isn't sung here.
            let words = lineTokens[i].filter { $0.start <= line.end }
            guard let first = words.first?.start, let last = words.last?.start else { continue }
            let length = last - first
            let morae = romanization[i].reduce(0) { $0 + moraCount($1.romaji) }
            guard length >= stretchedLineMinSec, morae > 0, length / Double(morae) >= stretchedSecPerMora else { continue }
            found.append(AlignmentMismatch(kind: .stretchedLine, start: line.start, end: line.end, lineIndex: i))
        }
        return found.sorted { $0.start < $1.start }
    }

    // The longest stretch of [from, to) that one sung region covers; nil when none overlaps it.
    static func longestSungRun(from: Double, to: Double, regions: [(start: Double, end: Double)]) -> (start: Double, end: Double)? {
        var best: (start: Double, end: Double)?
        for r in regions {
            let a = max(from, r.start), b = min(to, r.end)
            guard b > a else { continue }
            if best.map({ b - a > $0.end - $0.start }) ?? true { best = (a, b) }
        }
        return best
    }

    // The share of frames in [from, to) whose letter probability (everything but blank and the
    // pause class) reaches heardFrameMass.
    static func heardShare(in m: CTCEmissions.Matrix, from: Double, to: Double) -> Double {
        let C = CTCEmissions.classes, blank = CTCEmissions.blank, star = CTCEmissions.labels.firstIndex(of: "*")
        let f0 = max(0, Int(from / m.frameSec)), f1 = min(m.frames, Int(to / m.frameSec))
        guard f1 > f0 else { return 0 }
        var heard = 0
        for f in f0..<f1 {
            var mass: Float = 0
            for c in 0..<C where c != blank && c != star { mass += exp(m.values[f * C + c]) }
            if mass >= heardFrameMass { heard += 1 }
        }
        return Double(heard) / Double(f1 - f0)
    }

    // Morae in one romaji span: each vowel, syllabic ん and っ of its phoneme spelling.
    private static func moraCount(_ romaji: String) -> Int {
        RomajiPhonemes.encode(romaji).filter { "aiueoNQ".contains($0) }.count
    }
}
