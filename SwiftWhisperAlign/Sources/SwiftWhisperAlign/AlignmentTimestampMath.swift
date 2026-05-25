// Pure functions for cleaning up DTW-derived timestamps + selecting the right
// alignment-heads preset for a given Whisper model file. Extracted from
// ForcedAlignmentProvider so the orchestrator file stays under the 800-line
// guardrail; none of these functions reference provider instance state, which
// is exactly why they belong in a namespace rather than as methods.

import Foundation
import whisper_cpp

enum AlignmentTimestampMath {

    // Median of a Double array. Returns 0 for empty input.
    static func median(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // Repairs degenerate t_dtw values. Whisper sometimes emits t_dtw == 0
    // (or a value equal to the segment's t0) when DTW fails on a token,
    // producing runs of identical or out-of-order timestamps. We detect those
    // runs and linearly interpolate from the nearest good values on each side.
    static func repairDegenerateTimestamps(_ input: [Double]) -> [Double] {
        guard input.count >= 2 else { return input }
        var ts = input

        // Step 1: mark a timestamp as invalid when it is zero and not at the
        // very start, or when it breaks monotonicity. Keep the first valid
        // anchor to avoid losing genuine zero starts.
        var valid = [Bool](repeating: true, count: ts.count)
        for i in 0..<ts.count {
            if i > 0 && ts[i] == 0 { valid[i] = false; continue }
            if i > 0 && ts[i] < ts[i - 1] { valid[i] = false }
        }

        // Step 2: collapse runs of equal timestamps into "only the first is
        // valid" — the rest were duplicated by DTW failure, not real data.
        for i in 1..<ts.count where valid[i] && ts[i] == ts[i - 1] {
            valid[i] = false
        }

        // Step 3: interpolate invalid runs from the nearest valid neighbors.
        var i = 0
        while i < ts.count {
            if valid[i] { i += 1; continue }
            var j = i
            while j < ts.count && valid[j] == false { j += 1 }
            let leftIdx = i - 1
            let rightIdx = j
            let leftVal = leftIdx >= 0 ? ts[leftIdx] : 0.0
            let rightVal = rightIdx < ts.count ? ts[rightIdx] : (ts.last ?? leftVal) + 0.1
            let span = max(1, rightIdx - leftIdx)
            for k in i..<j {
                let frac = Double(k - leftIdx) / Double(span)
                ts[k] = leftVal + (rightVal - leftVal) * frac
            }
            i = j
        }

        return ts
    }

    // Returns the DTW alignment heads preset for the given model file.
    static func dtwPreset(for modelURL: URL) -> whisper_alignment_heads_preset {
        let name = modelURL.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("tiny.en") { return WHISPER_AHEADS_TINY_EN }
        if name.contains("tiny")    { return WHISPER_AHEADS_TINY }
        if name.contains("base.en") { return WHISPER_AHEADS_BASE_EN }
        if name.contains("base")    { return WHISPER_AHEADS_BASE }
        if name.contains("small.en") { return WHISPER_AHEADS_SMALL_EN }
        if name.contains("small")   { return WHISPER_AHEADS_SMALL }
        if name.contains("medium.en") { return WHISPER_AHEADS_MEDIUM_EN }
        if name.contains("medium")  { return WHISPER_AHEADS_MEDIUM }
        if name.contains("large-v3") { return WHISPER_AHEADS_LARGE_V3 }
        if name.contains("large-v2") { return WHISPER_AHEADS_LARGE_V2 }
        if name.contains("large-v1") || name.contains("large") { return WHISPER_AHEADS_LARGE_V1 }
        // Fallback: use top-most layers which works for any model.
        return WHISPER_AHEADS_N_TOP_MOST
    }
}
