// VoiceActivityDetector.swift
// Lightweight energy-based voice activity detector used to clamp
// forced-alignment line boundaries away from leading/trailing silence.
//
// Whisper DTW gives reasonable per-token timestamps but has no notion of
// "this frame is silence" — under forced alignment it can place a token's
// start inside the pre-roll silence or let a line's end drift past the last
// voiced frame. stable-ts's server pipeline uses VAD for the same purpose.

import Foundation

// Voiced/unvoiced mask over 16 kHz PCM frames at a fixed 20 ms hop.
// Frame i covers samples [i * hop, i * hop + window).
struct VoiceActivityDetector {
    // Hop and window in samples for 20 ms @ 16 kHz.
    static let hopSamples = 320
    static let windowSamples = 320
    static let frameDuration = 0.020
    private static let sampleRate = 16_000.0

    // Bitmap where mask[i] == true means frame i is considered voiced.
    let mask: [Bool]

    // Builds the VAD mask from mono 16 kHz float PCM.
    // Threshold is dynamic: frames whose RMS falls below
    //   max(absoluteFloor, percentile20 * k)
    // are classified as silence. This adapts to quiet recordings while still
    // rejecting pure background noise in loud ones.
    init(frames: [Float]) {
        guard frames.isEmpty == false else { self.mask = []; return }

        let frameCount = frames.count / Self.hopSamples
        guard frameCount > 0 else { self.mask = []; return }

        var rms = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let start = i * Self.hopSamples
            let end = min(start + Self.windowSamples, frames.count)
            var acc: Float = 0
            for j in start..<end { acc += frames[j] * frames[j] }
            rms[i] = (acc / Float(end - start)).squareRoot()
        }

        // 20th-percentile RMS is a robust estimate of the noise floor even when
        // more than half the signal is speech.
        let sorted = rms.sorted()
        let p20 = sorted[min(sorted.count - 1, sorted.count / 5)]
        // Absolute floor prevents false-positive "voice" in truly silent files.
        let absoluteFloor: Float = 0.003
        let threshold = max(absoluteFloor, p20 * 2.0)

        self.mask = rms.map { $0 >= threshold }
    }

    // Returns the nearest voiced time ≥ seconds, searching forward up to
    // maxSearch seconds. Falls back to the original value if no voiced frame
    // is found in the window — we never move the boundary more than we must.
    func clampForwardToVoiced(seconds: Double, maxSearch: Double = 0.5) -> Double {
        guard mask.isEmpty == false else { return seconds }
        let startFrame = frameIndex(for: seconds)
        let endFrame = min(mask.count - 1, frameIndex(for: seconds + maxSearch))
        guard startFrame <= endFrame else { return seconds }
        // Already voiced → no movement.
        if mask[startFrame] { return seconds }
        var i = startFrame
        while i <= endFrame {
            if mask[i] { return Double(i) * Self.frameDuration }
            i += 1
        }
        return seconds
    }

    // Returns the nearest voiced time ≤ seconds, searching backward up to
    // maxSearch seconds. Falls back to the original value if nothing voiced
    // is found in the window.
    func clampBackwardToVoiced(seconds: Double, maxSearch: Double = 0.5) -> Double {
        guard mask.isEmpty == false else { return seconds }
        let endFrame = frameIndex(for: seconds)
        let startFrame = max(0, frameIndex(for: seconds - maxSearch))
        guard startFrame <= endFrame else { return seconds }
        let clamped = min(endFrame, mask.count - 1)
        if clamped >= 0 && mask[clamped] {
            // Already voiced: return end of the voiced frame, not its start,
            // so captions don't cut off the final syllable.
            return Double(clamped + 1) * Self.frameDuration
        }
        var i = clamped
        while i >= startFrame {
            if mask[i] { return Double(i + 1) * Self.frameDuration }
            i -= 1
        }
        return seconds
    }

    // Maps a time in seconds to a frame index in the mask.
    private func frameIndex(for seconds: Double) -> Int {
        let idx = Int((seconds * Self.sampleRate) / Double(Self.hopSamples))
        return max(0, min(mask.count - 1, idx))
    }
}
