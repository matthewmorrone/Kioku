// EnergyVAD.swift
//
// Energy-based voice-activity detection on an isolated vocal stem. Its only consumer is the
// aligner, which uses the sung regions to pin the CTC path to blank through instrumental
// stretches — so a line can't be parked inside an interlude — and (via the cue gaps) to place
// ♪ markers.

import Foundation

enum EnergyVAD {
    // Sung regions in seconds, merged across gaps ≤ `maxGap` (breaths, consonant gaps).
    static func regions(_ samples: [Float], sampleRate: Int, maxGap: Double = 3.0) -> [(start: Double, end: Double)] {
        mergeSegments(segments(samples, sampleRate: sampleRate), maxGap: maxGap)
    }

    // Builds a smoothed RMS envelope, gates at a fraction of the stem's own loud-vocal level
    // (95th percentile), and groups frames above the gate into runs, tolerating sub-`minGapMs`
    // dips within a phrase. Unlike a speech VAD, sustained sung vowels keep energy up, so
    // phrases stay whole instead of fragmenting.
    private static func segments(
        _ samples: [Float], sampleRate: Int,
        gateFraction: Float = 0.2, minSpeechMs: Int = 300, minGapMs: Int = 350
    ) -> [(start: Double, end: Double)] {
        guard samples.count > sampleRate / 5 else { return [] }
        let frameLen = max(1, sampleRate / 50)   // 20 ms
        var env: [Float] = []
        env.reserveCapacity(samples.count / frameLen + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameLen, samples.count)
            var sum: Float = 0; var j = i
            while j < end { sum += samples[j] * samples[j]; j += 1 }
            env.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        // ~0.3 s centered smooth so brief transients don't fragment a phrase.
        let half = max(1, (sampleRate / frameLen) / 6)
        var sm = [Float](repeating: 0, count: env.count)
        for k in 0..<env.count {
            let lo = max(0, k - half), hi = min(env.count - 1, k + half)
            var s: Float = 0; for m in lo...hi { s += env[m] }
            sm[k] = s / Float(hi - lo + 1)
        }
        let sorted = sm.sorted()
        let ref = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        guard ref > 0 else { return [] }
        let gate = ref * gateFraction
        let fps = max(1, sampleRate / frameLen)
        let minSpeech = max(1, fps * minSpeechMs / 1000)
        let minGap = max(1, fps * minGapMs / 1000)

        var segs: [(start: Double, end: Double)] = []
        var k = 0
        while k < sm.count {
            if sm[k] > gate {
                let startF = k
                var endF = k, gap = 0, j = k
                while j < sm.count {
                    if sm[j] > gate { endF = j; gap = 0 }
                    else { gap += 1; if gap >= minGap { break } }
                    j += 1
                }
                if endF - startF + 1 >= minSpeech {
                    // No start-backoff here: mid-song, the audio before a segment is an
                    // instrumental break whose bleed keeps energy above any low floor, so a
                    // backoff walks the start across the break (measured 16–25 s early).
                    segs.append((Double(startF * frameLen) / Double(sampleRate),
                                 Double((endF + 1) * frameLen) / Double(sampleRate)))
                }
                k = j + 1
            } else { k += 1 }
        }
        return segs
    }

    // Merges segments separated by gaps ≤ `maxGap` into one region. Returns (start, end) sorted.
    private static func mergeSegments(_ segs: [(start: Double, end: Double)], maxGap: Double) -> [(start: Double, end: Double)] {
        var merged: [(start: Double, end: Double)] = []
        for s in segs.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, s.start - last.end <= maxGap {
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged
    }
}
