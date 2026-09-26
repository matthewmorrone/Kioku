// CTCAlignmentCore.swift
//
// Everything the aligner does after the model has run: the stem and raw-mix emission matrices,
// the isolated vocal stem and the romanized lyric in, per-line and per-span times out. Mix fill
// (EmissionDropoutFill) → frames outside the sung regions pinned to blank (EnergyVAD) → one CTC
// Viterbi pass over the whole lyric → onsets and line timings. Kept free of the model and audio
// plumbing so the Mac replay harness runs exactly this code on emissions the phone dumped.

import Foundation

enum CTCAlignmentCore {
    // CTC fires a token at the end of its phone, so a token's spike lands late by roughly a
    // consonant. The letter probability ramps up over the frames before the spike as the syllable
    // begins; a start is read at the foot of that ramp (walking back while the letter mass stays
    // above `onsetMassThreshold`, at most `onsetMaxBack` s). Measured on 12 songs against the
    // consensus reference: median line error 210 → 40 ms, early bias 210 → 10 ms, +4 lines,
    // versus the fixed 0.20 s lead this replaces.
    static let onsetMassThreshold: Float = 0.10
    static let onsetMaxBack = 0.4
    // Frames this far outside a sung region are pinned to blank.
    static let regionMargin = 0.5

    // Aligns the romanized lyric to the emissions. `stem` and `mix` are the MMS log-probabilities
    // for the vocal stem and the raw mix; `vocalMono` is the 44.1 kHz stem the sung regions are
    // read from. `log` receives the same breadcrumbs the device writes.
    static func align(
        stem: MMSEmissions.Matrix, mix: MMSEmissions.Matrix, vocalMono: [Float],
        lines: [String], romanization: [[RomanizedSpan]],
        log: ((String) -> Void)? = nil
    ) throws -> (lines: [AlignedLine], lineTokens: [[AlignedToken]]) {
        var matrix = stem
        let filled = EmissionDropoutFill.fill(stem: &matrix, mix: mix)
        log?("mix filled \(filled.frames) stem-quiet frames in \(filled.runs) run(s)")

        // Outside the sung regions the emissions are weak and near-blank, and the DP would
        // happily start the next line anywhere inside an interlude. Pinning those frames to
        // blank makes the sung regions the only place text can land.
        let vadRegions = EnergyVAD.regions(vocalMono, sampleRate: 44_100)
        log?("energy-VAD \(vadRegions.count) regions: " + vadRegions.prefix(12).map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: " "))
        let regions = droppingWordlessIntro(vadRegions, stem: stem, mix: mix)
        if regions.count < vadRegions.count { log?("wordless intro: dropped \(vadRegions.count - regions.count) leading region(s)") }
        if regions.isEmpty == false {
            var sung = [Bool](repeating: false, count: matrix.frames)
            for r in regions {
                let f0 = max(0, Int((r.start - regionMargin) / matrix.frameSec))
                let f1 = min(matrix.frames, Int((r.end + regionMargin) / matrix.frameSec))
                if f1 > f0 { for f in f0..<f1 { sung[f] = true } }
            }
            let C = MMSEmissions.classes
            for f in 0..<matrix.frames where sung[f] == false {
                for c in 0..<C { matrix.values[f * C + c] = -1e4 }
                matrix.values[f * C + MMSEmissions.blank] = 0
            }
        }

        // Flatten every span's romaji into one token sequence, remembering each span's range. An
        // optional star (MMS's "any vocal" class) at each end of the song absorbs wordless intros and
        // fades so they can't capture the first or last line. Between lines it would also eat weak
        // short lines (measured: セラヴィ's 駆け抜けて), so it is only placed at the edges.
        let star = MMSEmissions.labels.firstIndex(of: "*")
        var tokens: [Int] = star.map { [$0] } ?? []
        var spanTokenRanges: [[Range<Int>]] = []   // per line, per span
        for lineSpans in romanization {
            var ranges: [Range<Int>] = []
            for span in lineSpans {
                let start = tokens.count
                for ch in span.romaji {
                    if let idx = MMSEmissions.labels.firstIndex(of: ch), idx != MMSEmissions.blank {
                        tokens.append(idx)
                    }
                }
                ranges.append(start..<tokens.count)
            }
            spanTokenRanges.append(ranges)
        }
        guard tokens.count > (star == nil ? 0 : 1) else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The lyrics romanized to nothing alignable."])
        }
        if let star { tokens.append(star) }
        var optional = [Bool](repeating: false, count: tokens.count)
        if star != nil { optional[0] = true; optional[tokens.count - 1] = true }
        guard let spans = CTCViterbi.align(logProbs: matrix.values, frames: matrix.frames,
                                           classes: MMSEmissions.classes, tokens: tokens, optional: optional) else {
            throw NSError(domain: "SwiftWhisperAlign.CTC", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "The lyrics don't fit the sung audio (more text than the song can hold)."])
        }
        log?("viterbi placed \(tokens.count) tokens")

        let onsets = onsetFrames(matrix: matrix)
        let durationSec = Double(vocalMono.count) / 44_100
        let timed = lineTimings(
            lines: lines, romanization: romanization, spanTokenRanges: spanTokenRanges,
            tokenSpans: spans, onsetOf: { onsets[$0] }, frameSec: matrix.frameSec, durationSec: durationSec
        )
        let spread = RepeatedLineSpreader.spread(lines: timed.lines, lineTokens: timed.lineTokens, regions: regions, durationSec: durationSec)
        let moved = zip(timed.lines, spread.lines).filter { $0.start != $1.start }.count
        if moved > 0 { log?("repeated lines: re-spread \(moved) stacked copy(ies)") }
        return spread
    }

    // A letter probability this high on some frame, in the stem or the raw mix, means the model
    // heard a word there. Low on purpose: ムーンプライド's first line peaks at 0.044 in the stem and
    // 0.089 in the mix, ムーンハートシークエンス's wordless "oooo" at 0.042 and 0.018.
    static let heardLetterProbability: Float = 0.05

    // Drops the sung regions before the first one in which the model hears any letter (in the
    // stem or the raw mix). A vocal intro ("oooo") gives the model nothing, and before the first
    // heard word there is no line to lose, while leaving the intro in lets a weak first line
    // (ムーンハートシークエンス's first セーラームーン) be placed on it. Keeps every region when no
    // region is heard at all.
    static func droppingWordlessIntro(_ regions: [(start: Double, end: Double)], stem: MMSEmissions.Matrix, mix: MMSEmissions.Matrix) -> [(start: Double, end: Double)] {
        let C = MMSEmissions.classes, blank = MMSEmissions.blank, star = MMSEmissions.labels.firstIndex(of: "*")
        func isHeard(_ r: (start: Double, end: Double)) -> Bool {
            for m in [stem, mix] {
                let f0 = max(0, Int(r.start / m.frameSec)), f1 = min(m.frames, Int(r.end / m.frameSec))
                guard f1 > f0 else { continue }
                for f in f0..<f1 {
                    for c in 0..<C where c != blank && c != star && exp(m.values[f * C + c]) >= heardLetterProbability { return true }
                }
            }
            return false
        }
        guard let firstHeard = regions.firstIndex(where: isHeard) else { return regions }
        return Array(regions[firstHeard...])
    }

    // For every frame, the frame where the letter-mass ramp leading up to it begins (see
    // `onsetMassThreshold`): a token whose spike is at frame f starts at onsets[f].
    private static func onsetFrames(matrix: MMSEmissions.Matrix) -> [Int] {
        let C = MMSEmissions.classes, blank = MMSEmissions.blank, star = MMSEmissions.labels.firstIndex(of: "*")
        var mass = [Float](repeating: 0, count: matrix.frames)
        for f in 0..<matrix.frames {
            var m: Float = 0
            for c in 0..<C where c != blank && c != star { m += exp(matrix.values[f * C + c]) }
            mass[f] = m
        }
        let maxBack = Int(onsetMaxBack / matrix.frameSec)
        return (0..<matrix.frames).map { spike in
            var f = spike
            while f > 0, spike - f < maxBack, mass[f - 1] >= onsetMassThreshold { f -= 1 }
            return f
        }
    }

    // Turns token spans into per-line timings and per-span checkpoints. A line starts at the
    // onset of its first placed token and ends at its last; the end is bridged to the
    // next line's start when the gap is short (a held final vowel plus a breath — CTC leaves
    // the token as soon as the phone is recognizable, so its own end lands well before the
    // singer stops), while a longer gap stays open for a ♪ marker.
    private static func lineTimings(
        lines: [String], romanization: [[RomanizedSpan]], spanTokenRanges: [[Range<Int>]],
        tokenSpans: [(start: Int, end: Int)], onsetOf: (Int) -> Int, frameSec: Double, durationSec: Double
    ) -> (lines: [AlignedLine], lineTokens: [[AlignedToken]]) {
        let sustainedVowelGap = 4.0
        let bridgeMargin = 0.05
        let perceptualOffset = 0.20
        func time(_ frame: Int) -> Double { Double(frame) * frameSec }

        // Per line: first/last placed token frames (nil when the line romanized to nothing).
        var lineStart: [Double?] = []
        var lineEnd: [Double?] = []
        for ranges in spanTokenRanges {
            let placed = ranges.flatMap { Array($0) }
            if let first = placed.first, let last = placed.last {
                lineStart.append(time(onsetOf(tokenSpans[first].start)))
                lineEnd.append(time(tokenSpans[last].end))
            } else {
                lineStart.append(nil); lineEnd.append(nil)
            }
        }
        // A line with no tokens borrows its neighbours' boundary so it is never dropped.
        for i in lines.indices where lineStart[i] == nil {
            let prevEnd = (0..<i).reversed().compactMap { lineEnd[$0] }.first ?? 0
            let nextStart = ((i + 1)..<lines.count).compactMap { lineStart[$0] }.first ?? durationSec
            lineStart[i] = prevEnd
            lineEnd[i] = min(nextStart, prevEnd + 0.3)
        }

        var result: [AlignedLine] = []
        var lineTokens: [[AlignedToken]] = []
        for i in lines.indices {
            let start = lineStart[i]!
            let nextBound = (i + 1 < lines.count) ? lineStart[i + 1]! : durationSec
            let ctcEnd = lineEnd[i]! + perceptualOffset
            let gapAfter = nextBound - ctcEnd
            let extendedEnd = (gapAfter > 0 && gapAfter <= sustainedVowelGap) ? nextBound - bridgeMargin : ctcEnd
            let end = max(start + 0.3, min(extendedEnd, nextBound, start + 9.0))
            result.append(AlignedLine(text: lines[i], start: start, end: end))

            var tokens: [AlignedToken] = []
            var lastStart = -Double.infinity
            for (span, range) in zip(romanization[i], spanTokenRanges[i]) {
                guard let first = range.first else { continue }
                var t = max(start, time(onsetOf(tokenSpans[first].start)))
                // Keep checkpoints distinct and forward-only, clamped to the line end.
                if t < lastStart + 0.1 { t = min(lastStart + 0.1, end) }
                lastStart = t
                tokens.append(AlignedToken(start: t, charOffsetUTF16: span.charOffsetUTF16, charLengthUTF16: span.charLengthUTF16))
            }
            lineTokens.append(tokens)
        }
        return (result, lineTokens)
    }
}
