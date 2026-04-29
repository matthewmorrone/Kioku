// NonSpeechDetector.swift
// Ports stable-ts's non-VAD silence detection (wav2mask / audio2timings from
// stable_whisper/stabilization/nonvad.py) to Swift.
//
// Produces a list of [start, end] silent intervals over the full audio,
// used by the chunked driver for leading-silence skip and by the final
// line-boundary pass for silence suppression. This is the same signal
// stable-ts feeds into Aligner._skip_nonspeech and WhisperResult.suppress_silence
// when Silero VAD is disabled.

import Foundation

// Immutable silent-interval list derived from mono 16 kHz float PCM.
// Intervals are half-open [start, end) in seconds, sorted ascending and
// non-overlapping.
struct NonSpeechDetector {
    // Seconds, each sorted ascending.
    let silentStarts: [Double]
    let silentEnds: [Double]
    let audioDuration: Double

    // Direct initializer used by alternative detectors (e.g. Silero VAD)
    // that have already produced a list of silent intervals. Keeps the
    // callers of skipLeadingSilence / suppressStartSilence agnostic to
    // which detector produced the data.
    init(silentStarts: [Double], silentEnds: [Double], audioDuration: Double) {
        self.silentStarts = silentStarts
        self.silentEnds = silentEnds
        self.audioDuration = audioDuration
    }

    // Ports the following stable-ts pipeline:
    //   1. Per-token absolute-value downsample at N_SAMPLES_PER_TOKEN = 320
    //      samples (50 tokens / second at 16 kHz).
    //   2. Normalize by 99.9th percentile × 1.75 (clipped to 1.0).
    //   3. Reflect-pad + average-pool with kernel size 5.
    //   4. Quantize at q_levels = 20; zeros mark silence.
    //   5. Drop loud runs shorter than 0.1 s (treat as noise).
    //   6. Emit silent intervals as the gaps between the surviving loud runs.
    init(frames: [Float], sampleRate: Int = 16_000) {
        let samplesPerToken = 320
        let tokensPerSecond: Double = Double(sampleRate) / Double(samplesPerToken)
        let tokenDuration: Double = 1.0 / tokensPerSecond

        let count = frames.count
        self.audioDuration = Double(count) / Double(sampleRate)

        guard count >= samplesPerToken else {
            self.silentStarts = []
            self.silentEnds = []
            return
        }

        // Step 1: per-token max-abs loudness. Using max within each hop rather
        // than stable-ts's linear-interpolation downsample; same intent,
        // slightly more conservative (louder short spikes survive).
        let tokenCount = (count / samplesPerToken) + 1
        var loudness = [Float](repeating: 0, count: tokenCount)
        for i in 0..<tokenCount {
            let s = i * samplesPerToken
            let e = min(s + samplesPerToken, count)
            guard s < e else { continue }
            var m: Float = 0
            for j in s..<e {
                let v = abs(frames[j])
                if v > m { m = v }
            }
            loudness[i] = m
        }

        // Step 2: 99.9th-percentile normalization.
        let k = max(1, Int(ceil(Double(count) * 0.001)))
        let sortedDesc = loudness.sorted(by: >)
        let percentile999 = sortedDesc[min(k - 1, sortedDesc.count - 1)]
        let norm = max(Float(1e-5), min(Float(1), percentile999 * 1.75))
        if norm > 0 {
            for i in 0..<tokenCount { loudness[i] = loudness[i] / norm }
        }

        // Step 3: reflect-padded avg-pool, kernel size 5.
        let kSize = 5
        let pad = kSize / 2
        var pooled = [Float](repeating: 0, count: tokenCount)
        for i in 0..<tokenCount {
            var sum: Float = 0
            for j in -pad...pad {
                var idx = i + j
                if idx < 0 { idx = -idx }
                if idx >= tokenCount { idx = 2 * (tokenCount - 1) - idx }
                if idx < 0 { idx = 0 }
                if idx >= tokenCount { idx = tokenCount - 1 }
                sum += loudness[idx]
            }
            pooled[i] = sum / Float(kSize)
        }

        // Step 4: quantize and threshold. Anything that rounds to zero after
        // multiplying by 20 is silence.
        let qLevels: Float = 20
        var loudMask = [Bool](repeating: false, count: tokenCount)
        for i in 0..<tokenCount {
            loudMask[i] = (pooled[i] * qLevels).rounded() > 0
        }

        // Step 5: extract contiguous loud runs and drop runs under 0.1 s.
        let minLoudTokens = max(1, Int(ceil(0.1 * tokensPerSecond)))
        var loudRuns: [(Int, Int)] = []
        var c = 0
        while c < tokenCount {
            guard loudMask[c] else { c += 1; continue }
            var e = c
            while e < tokenCount && loudMask[e] { e += 1 }
            if e - c >= minLoudTokens {
                loudRuns.append((c, e))
            }
            c = e
        }

        // Step 6: silent intervals are the gaps between surviving loud runs,
        // including leading and trailing silence.
        var starts: [Double] = []
        var ends: [Double] = []
        var lastEnd = 0
        for (s, e) in loudRuns {
            if s > lastEnd {
                starts.append(Double(lastEnd) * tokenDuration)
                ends.append(Double(s) * tokenDuration)
            }
            lastEnd = e
        }
        if lastEnd < tokenCount {
            starts.append(Double(lastEnd) * tokenDuration)
            ends.append(Double(tokenCount) * tokenDuration)
        }

        self.silentStarts = starts
        self.silentEnds = ends
    }

    // Ports stable-ts's _skip_nonspeech for the chunked driver: if a silent
    // region at least `minSilence` seconds long contains `fromSeconds`, return
    // the end of that region so the caller can advance past it. Otherwise
    // returns the input unchanged.
    //
    // Parameter slack accounts for the per-token resolution (20 ms) so a
    // token landing in the last frame of a silent run still counts as being
    // inside it.
    func skipLeadingSilence(fromSeconds: Double, minSilence: Double = 5.0, slack: Double = 0.25) -> Double {
        for i in 0..<silentStarts.count {
            let s = silentStarts[i]
            let e = silentEnds[i]
            if (e - s) < minSilence { continue }
            if fromSeconds >= s - slack && fromSeconds < e - slack {
                return e
            }
            if s > fromSeconds { break }
        }
        return fromSeconds
    }

    // Ports the start-overlap branch of stable_whisper/stabilization/__init__.py
    // suppress_silence(): if a silent interval straddles a line's start
    // boundary (silence starts at or before the line and ends inside the
    // line), push the line's start forward to the silence end. Mirrors
    // keep_end=True, which is the default for alignment.
    //
    // Returns the adjusted (start, end) pair. If no overlap, returns the
    // input pair unchanged. min_word_dur guards against collapsing the line
    // to zero duration.
    func suppressStartSilence(start: Double, end: Double, minWordDur: Double = 0.1) -> (Double, Double) {
        guard (end - start) > minWordDur else { return (start, end) }
        for i in 0..<silentStarts.count {
            let s = silentStarts[i]
            let e = silentEnds[i]
            if e <= start { continue }
            if s > start { break }
            // s <= start < e and e <= end → straddles start.
            if start < e && e <= end {
                let newStart = min(e, end - minWordDur)
                return (newStart, end)
            }
        }
        return (start, end)
    }

    // Mirror of suppressStartSilence for the trailing edge: if a silent
    // interval straddles the line's end, pull the end back to the silence
    // start. Not invoked by default (stable-ts keep_end=True), but available
    // for symmetry.
    func suppressEndSilence(start: Double, end: Double, minWordDur: Double = 0.1) -> (Double, Double) {
        guard (end - start) > minWordDur else { return (start, end) }
        for i in 0..<silentStarts.count {
            let s = silentStarts[i]
            let se = silentEnds[i]
            if se <= start { continue }
            if s >= end { break }
            if start <= s && s < end && end <= se {
                let newEnd = max(s, start + minWordDur)
                return (start, newEnd)
            }
        }
        return (start, end)
    }
}
