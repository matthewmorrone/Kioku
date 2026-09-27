import Foundation

// A song's beat grid and loudness curve, precomputed once from the audio file by
// SongPulseAnalyzer, for the lyrics view's interlude ♪ notes. Answers two questions for any
// playback time: how loud the music is relative to the rest of this song (so an intro swelling
// into the full band reads as a jump in size), and how far past the last pulsing beat we are (so
// the notes hit on the actual beats). Quiet stretches pulse every other beat and loud ones every
// beat, so the notes also speed up when the song gets big.
nonisolated struct SongPulseMap: Sendable {
    // Beat times in seconds, ascending.
    let beatTimes: [Double]
    // Per beat: whether it falls in a quiet stretch that pulses only on even beats.
    let halfTime: [Bool]
    // Per analysis frame: loudness in [0, 1] relative to this song's own quiet…loud range.
    let loudness: [Float]
    let frameSeconds: Double

    // How quickly a beat's pulse fades, in seconds.
    private static let pulseDecay = 0.16

    // Relative loudness at `t` seconds, 0 outside the analysed range.
    func loudness(at t: Double) -> Double {
        guard loudness.isEmpty == false, t >= 0 else { return 0 }
        let index = min(loudness.count - 1, Int(t / frameSeconds))
        return Double(loudness[index])
    }

    // 1 at a pulsing beat, decaying toward 0 until the next one; 0 before the first beat and
    // well after the last.
    func pulse(at t: Double) -> Double {
        guard let k = pulsingBeatIndex(at: t) else { return 0 }
        return exp(-(t - beatTimes[k]) / Self.pulseDecay)
    }

    // Index of the beat whose hit is currently showing — the last beat at or before `t`, or the
    // one before it when that beat is a silent odd beat in a half-time stretch.
    private func pulsingBeatIndex(at t: Double) -> Int? {
        guard let k = lastBeatIndex(atOrBefore: t) else { return nil }
        let pulsing = (halfTime[k] && k % 2 == 1) ? k - 1 : k
        return pulsing >= 0 ? pulsing : nil
    }

    // Binary search for the last beat at or before `t`.
    private func lastBeatIndex(atOrBefore t: Double) -> Int? {
        var lo = 0
        var hi = beatTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beatTimes[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
