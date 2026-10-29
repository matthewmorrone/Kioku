// SungOrderDecoder.swift
//
// The aligner keeps the note's line order, so a note whose lines are sung in another order still
// gets every line placed, just in the wrong spots. This decoder drops that order: any line may
// follow any other, or a filler may take frames no line fits, and one Viterbi pass picks the
// lines that best explain the emissions and where. The lines it picks, in time order, are a guess
// at the order actually sung; the stretches only filler explains, where words are heard, are
// lyrics the note doesn't have. It runs only after the alignment flagged mismatches: on correct
// notes it still jumps to similar-sounding lines now and then (1–5 per song on three correct songs),
// so it is a suggestion for a song already in doubt, never a check of its own.

import Foundation

enum SungOrderDecoder {
    // Cost per frame of the filler (in log-probability below the frame's best class). Lower lets
    // the filler take sung words a line should have; higher makes lines stretch over lyrics the
    // note lacks. Tuned on 乙女のススメ (3 finds lines 2 drops).
    static let fillerCost: Float = 3
    // Cost of starting a line, so a line isn't matched to a few stray phonemes. 10 lost 乙女の
    // ススメ's opening line and its 0:40 乙女たるもの, which 5 finds.
    static let lineEntryCost: Float = 5

    // The sung order for `romanization` (one entry per lyric line) in `matrix`, with the stretches
    // of heard singing no line explains; nil when the order found is the note's own (nothing to
    // suggest). `regions` and `stem` gate the unheard stretches as AlignmentMismatchDetector does.
    static func decode(
        matrix: CTCEmissions.Matrix, romanization: [[RomanizedSpan]],
        regions: [(start: Double, end: Double)], stem: CTCEmissions.Matrix?, durationSec: Double
    ) -> [SungOrderEntry]? {
        let found = bestPath(matrix: matrix, lines: romanization.map { SingPhonemeScorer.tokens(fromRomaji: $0.map(\.romaji)) })
        guard found.isEmpty == false else { return nil }
        let inNoteOrder = zip(found, found.dropFirst()).allSatisfy { $1.line == $0.line + 1 }
            && found.first?.line == 0 && found.last?.line == romanization.count - 1
        guard inNoteOrder == false else { return nil }

        var entries: [SungOrderEntry] = []
        var cursor = 0.0
        // Each stretch between found lines (and after the last) is checked for heard singing.
        let bounds = found.map { (Double($0.startFrame) * matrix.frameSec, Double($0.endFrame) * matrix.frameSec, $0.line as Int?) }
            + [(durationSec, durationSec, nil)]
        for (start, end, line) in bounds {
            if start > cursor, let sung = AlignmentMismatchDetector.longestSungRun(from: cursor, to: start, regions: regions),
               sung.end - sung.start >= AlignmentMismatchDetector.unmatchedSingingMinSec,
               stem.map({ AlignmentMismatchDetector.heardShare(in: $0, from: sung.start, to: sung.end) >= AlignmentMismatchDetector.heardFrameShare }) ?? true {
                entries.append(SungOrderEntry(start: sung.start, end: sung.end, lineIndex: nil))
            }
            if let line { entries.append(SungOrderEntry(start: start, end: end, lineIndex: line)) }
            cursor = max(cursor, end)
        }
        return entries
    }

    // One Viterbi pass over a loop of every line (a CTC chain per line) plus a between-lines state
    // that emits blank or filler. Returns the lines on the best path in time order, each with the
    // frames it spans (end exclusive). Scores are each frame's log-probabilities minus its best, so
    // a frame's cost doesn't depend on how loud the singing is.
    private static func bestPath(matrix: CTCEmissions.Matrix, lines: [[Int]]) -> [(line: Int, startFrame: Int, endFrame: Int)] {
        let C = CTCEmissions.classes, blank = CTCEmissions.blank, T = matrix.frames
        let neg = -Float.infinity
        // Per line: its state labels (blank, token, blank, token, … blank).
        let labels: [[Int]] = lines.map { tokens in
            var l = [blank]
            for t in tokens { l += [t, blank] }
            return tokens.isEmpty ? [] : l
        }
        var score = labels.map { [Float](repeating: neg, count: $0.count) }
        var started = labels.map { [Int](repeating: 0, count: $0.count) }
        var next = score, nextStarted = started
        var between: Float = 0
        // For each frame, the line (and its start frame) the between state was entered from there;
        // nil when it stayed between lines.
        var cameFrom = [(line: Int, start: Int)?](repeating: nil, count: T)

        for f in 0..<T {
            let row = f * C
            var best: Float = neg
            for c in 0..<C { best = max(best, matrix.values[row + c]) }
            @inline(__always) func cost(_ c: Int) -> Float { matrix.values[row + c] - best }
            let filler = max(cost(blank), -fillerCost)

            var stay = between + filler
            var from: (line: Int, start: Int)?
            let entry = between - lineEntryCost
            for li in labels.indices where labels[li].isEmpty == false {
                let lab = labels[li], S = lab.count
                // Leaving the line (from its last token or the blank after it) into the between state.
                let last = score[li][S - 2] >= score[li][S - 1] ? S - 2 : S - 1
                if score[li][last] + filler > stay {
                    stay = score[li][last] + filler
                    from = (li, started[li][last])
                }
                for s in 0..<S {
                    var v = score[li][s], v0 = started[li][s]
                    if s >= 1, score[li][s - 1] > v { v = score[li][s - 1]; v0 = started[li][s - 1] }
                    if s >= 3, s & 1 == 1, lab[s] != lab[s - 2], score[li][s - 2] > v { v = score[li][s - 2]; v0 = started[li][s - 2] }
                    if s <= 1, entry > v { v = entry; v0 = f }
                    next[li][s] = v == neg ? neg : v + cost(lab[s])
                    nextStarted[li][s] = v0
                }
            }
            swap(&score, &next)
            swap(&started, &nextStarted)
            between = stay
            cameFrom[f] = from
        }

        var found: [(line: Int, startFrame: Int, endFrame: Int)] = []
        var f = T - 1
        while f > 0 {
            if let from = cameFrom[f] {
                found.append((from.line, from.start, f))
                f = from.start - 1
            } else {
                f -= 1
            }
        }
        return found.reversed()
    }
}
