import Foundation

// Reads a coarse "how big and how busy is the music right now" from the player's level meter, for
// the lyrics view's interlude ♪ notes: loudness sets their size, and the rate of onsets (the level
// jumping above its recent baseline — drum hits, a band coming in) sets how fast they pulse. A quiet
// intro gets small, slow notes; a loud, dense section gets big, quick ones. Fed from the playback
// timer only, so the pulse phase freezes on pause and resumes where it was.
final class InterludeRhythm {
    // Slow loudness in [0, 1] (the meter's -50…0 dB range) and the pulse phase in cycles.
    private(set) var loudness: Double = 0
    private(set) var phase: Double = 0

    private var baseline: Double = 0
    private var lastOnset: TimeInterval = -.infinity
    private var onsets: [TimeInterval] = []
    private var pulsesPerSecond = restingRate

    // A jump this far above the baseline, at least `minOnsetGap` after the last one, is an onset.
    private static let onsetJump = 0.06
    private static let minOnsetGap = 0.18
    // Onsets are counted over this window.
    private static let window = 4.0
    // Pulse rate with no onsets, and the fastest it may go.
    private static let restingRate = 0.7
    private static let fastestRate = 3.0

    // Advances by `dt` seconds of playback at time `t` with the raw (unsmoothed) meter level.
    func feed(level: Double, dt: Double, at t: TimeInterval) {
        loudness += (level - loudness) * min(1, dt / 1.5)
        if level - baseline > Self.onsetJump, t - lastOnset >= Self.minOnsetGap {
            onsets.append(t)
            lastOnset = t
        }
        baseline += (level - baseline) * min(1, dt / 0.4)
        onsets.removeAll { t - $0 > Self.window }
        let target = min(Self.fastestRate, max(Self.restingRate, Double(onsets.count) / Self.window))
        pulsesPerSecond += (target - pulsesPerSecond) * min(1, dt / 1.0)
        phase += dt * pulsesPerSecond
    }

    // Clears the onset history (after a seek or a new file), keeping the phase so notes don't jump.
    func reset() {
        loudness = 0
        baseline = 0
        onsets = []
        lastOnset = -.infinity
        pulsesPerSecond = Self.restingRate
    }
}
