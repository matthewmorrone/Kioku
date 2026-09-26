import Foundation

// Vocal isolation sometimes erases a sung passage outright (doubled or heavily processed vocals
// get routed to the other stems), and the aligner then hears nothing there and slides every
// following line late. Where the STEM's emissions carry no letter evidence for a sustained run
// but the raw MIX's do, the mix's frames stand in. Short quiet gaps (breaths, rests) are left
// alone because the mix hallucinates letters over instruments; measured on 12 songs, a 2 s
// minimum run fixes the dropout song without losing lines elsewhere.
enum EmissionDropoutFill {
    static let threshold: Float = 0.05     // smoothed non-blank probability below which a frame is "quiet"
    static let smoothSec = 1.0             // ± window for the non-blank average
    static let minRunSec = 2.0             // shortest stem-quiet run the mix may fill

    // Substitutes mix frames into `stem` inside every qualifying run; returns what was replaced.
    static func fill(stem: inout MMSEmissions.Matrix, mix: MMSEmissions.Matrix) -> (frames: Int, runs: Int) {
        let C = MMSEmissions.classes, blank = MMSEmissions.blank
        let n = min(stem.frames, mix.frames)
        guard n > 0 else { return (0, 0) }
        let stemMass = smoothed(nonBlank(stem, frames: n, classes: C, blank: blank), half: Int(smoothSec / stem.frameSec))
        let mixMass = smoothed(nonBlank(mix, frames: n, classes: C, blank: blank), half: Int(smoothSec / stem.frameSec))
        let minRun = Int(minRunSec / stem.frameSec)
        var replaced = 0, runs = 0, f = 0
        while f < n {
            guard stemMass[f] < threshold, mixMass[f] > threshold else { f += 1; continue }
            var g = f
            while g < n, stemMass[g] < threshold, mixMass[g] > threshold { g += 1 }
            if g - f >= minRun {
                for k in f..<g { for c in 0..<C { stem.values[k * C + c] = mix.values[k * C + c] } }
                replaced += g - f; runs += 1
            }
            f = g
        }
        return (replaced, runs)
    }

    // Smoothed stem letter mass below which a frame inside a sung region counts as deaf, and the
    // shortest deaf run the mix may fill.
    static var deafThreshold: Float = 0.003
    static var deafMinRunSec = 4.0
    // On; the replay harness can switch it off to compare.
    static var isDeafFillEnabled = true

    // Substitutes mix frames wherever the stem has singing (inside `sung`, the energy-VAD regions)
    // but the model hears no letters in it for a sustained run, whatever the mix's own score. The
    // shipped `fill` needs the mix to clear `threshold`, which misses a passage the model barely
    // hears in either signal (ムーンプライド 44–62 s: stem ~0, mix 0.01–0.02) and leaves those lines
    // nothing to lock onto. Runs after `fill`, so frames it already replaced aren't touched.
    static func fillDeaf(stem: inout MMSEmissions.Matrix, mix: MMSEmissions.Matrix, sung: [(start: Double, end: Double)]) -> (frames: Int, runs: Int) {
        let C = MMSEmissions.classes, blank = MMSEmissions.blank
        let n = min(stem.frames, mix.frames)
        guard n > 0 else { return (0, 0) }
        let stemMass = smoothed(nonBlank(stem, frames: n, classes: C, blank: blank), half: Int(smoothSec / stem.frameSec))
        var inSung = [Bool](repeating: false, count: n)
        for r in sung {
            let f0 = max(0, Int(r.start / stem.frameSec)), f1 = min(n, Int(r.end / stem.frameSec))
            if f1 > f0 { for f in f0..<f1 { inSung[f] = true } }
        }
        let minRun = Int(deafMinRunSec / stem.frameSec)
        var replaced = 0, runs = 0, f = 0
        while f < n {
            guard inSung[f], stemMass[f] < deafThreshold else { f += 1; continue }
            var g = f
            while g < n, inSung[g], stemMass[g] < deafThreshold { g += 1 }
            if g - f >= minRun {
                for k in f..<g { for c in 0..<C { stem.values[k * C + c] = mix.values[k * C + c] } }
                replaced += g - f; runs += 1
            }
            f = g
        }
        return (replaced, runs)
    }

    // Per-frame probability mass on the letter classes. Summed directly rather than as 1 − blank,
    // because the export also carries a star class that shares the blank's mass.
    private static func nonBlank(_ m: MMSEmissions.Matrix, frames: Int, classes: Int, blank: Int) -> [Float] {
        let star = MMSEmissions.labels.firstIndex(of: "*")
        return (0..<frames).map { f in
            var mass: Float = 0
            for c in 0..<classes where c != blank && c != star { mass += exp(m.values[f * classes + c]) }
            return mass
        }
    }

    // Box average over ±half frames, shrinking at the edges.
    private static func smoothed(_ v: [Float], half: Int) -> [Float] {
        var prefix = [Float](repeating: 0, count: v.count + 1)
        for i in 0..<v.count { prefix[i + 1] = prefix[i] + v[i] }
        return (0..<v.count).map { i in
            let lo = max(0, i - half), hi = min(v.count - 1, i + half)
            return (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
        }
    }
}
