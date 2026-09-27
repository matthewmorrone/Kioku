import Accelerate
import AVFoundation

// Builds a SongPulseMap from an audio file: a spectral-flux onset envelope, a tempo from its
// autocorrelation, a dynamic-programming beat track (Ellis 2007) that follows the song's actual
// hits, and a loudness curve normalized to the song's own range. Runs off the main thread once per
// loaded file; a four-minute song takes a fraction of a second.
nonisolated enum SongPulseAnalyzer {
    private static let targetRate = 22_050.0
    private static let log2FFT: vDSP_Length = 10
    private static let fftSize = 1024
    private static let hop = 256
    // How strongly the beat track holds to the global tempo versus chasing individual onsets.
    private static let tightness = 100.0
    // Loudness above this (relative) switches a stretch to pulsing every beat; below `quietBelow`
    // switches it back to every other beat. The gap keeps it from flickering.
    private static let loudAbove: Float = 0.55
    private static let quietBelow: Float = 0.35

    // Reads `url` and returns its pulse map, or nil when the file can't be read or is silent.
    static func analyze(url: URL) -> SongPulseMap? {
        guard let (samples, rate) = monoSamples(url: url), samples.count > fftSize * 4 else { return nil }
        let frameSeconds = Double(hop) / rate
        let (flux, levelDb) = spectralFluxAndLevel(samples)
        let envelope = onsetEnvelope(flux, frameSeconds: frameSeconds)
        guard let period = tempoPeriod(envelope, frameSeconds: frameSeconds) else { return nil }
        let loudness = relativeLoudness(levelDb, frameSeconds: frameSeconds)
        let beatFrames = trackBeats(envelope, period: period).filter { levelDb[$0] > -50 }
        guard beatFrames.count > 1 else { return nil }
        let halfTime = halfTimeFlags(beatFrames.map { loudness[$0] })
        return SongPulseMap(
            beatTimes: beatFrames.map { Double($0) * frameSeconds },
            halfTime: halfTime,
            loudness: loudness,
            frameSeconds: frameSeconds
        )
    }

    // Decodes the file in chunks, downmixed to mono and decimated to roughly 22 kHz by averaging
    // (onsets and loudness don't need the top octave).
    private static func monoSamples(url: URL) -> ([Float], Double)? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            AppLog.error(.audioPlayback, "[SongPulseAnalyzer] open failed: \(error.localizedDescription)")
            return nil
        }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let decimation = max(1, Int((format.sampleRate / targetRate).rounded()))
        let chunk: AVAudioFrameCount = 65_536
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / decimation + 1)
        var accumulator: Float = 0
        var accumulated = 0
        // Bounded by the file's length: reading at the end throws rather than returning 0 frames.
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                AppLog.error(.audioPlayback, "[SongPulseAnalyzer] read failed: \(error.localizedDescription)")
                return nil
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            let scale = 1 / Float(channels * decimation)
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += data[ch][i] }
                accumulator += sum
                accumulated += 1
                if accumulated == decimation {
                    out.append(accumulator * scale)
                    accumulator = 0
                    accumulated = 0
                }
            }
        }
        return (out, format.sampleRate / Double(decimation))
    }

    // Per hop: half-wave-rectified increase in log spectral magnitude (spectral flux — a note or
    // drum hit starting), and the frame's RMS level in dB.
    private static func spectralFluxAndLevel(_ samples: [Float]) -> ([Float], [Float]) {
        let half = fftSize / 2
        let frameCount = (samples.count - fftSize) / hop + 1
        guard let setup = vDSP_create_fftsetup(log2FFT, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frameCount)
        var levelDb = [Float](repeating: -100, count: frameCount)
        for f in 0..<frameCount {
            let start = f * hop
            samples.withUnsafeBufferPointer { sp in
                let frame = UnsafeBufferPointer(rebasing: sp[start..<(start + fftSize)])
                vDSP.multiply(frame, window, result: &windowed)
                levelDb[f] = 20 * log10(max(1e-6, vDSP.rootMeanSquare(frame)))
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2FFT, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            // Bin 0 packs DC and Nyquist together; skip it. log1p compresses so quiet
            // instruments' onsets register next to loud ones.
            var sum: Float = 0
            for b in 1..<half {
                let m = log1p(50 * magnitudes[b])
                if f > 0 { sum += max(0, m - previous[b]) }
                previous[b] = m
            }
            flux[f] = sum
        }
        return (flux, levelDb)
    }

    // Flux minus its half-second local mean, rectified and scaled to unit deviation, so a steady
    // wash of sound doesn't read as onsets and loud and quiet sections weigh comparably.
    private static func onsetEnvelope(_ flux: [Float], frameSeconds: Double) -> [Float] {
        let n = flux.count
        let radius = max(1, Int(0.25 / frameSeconds))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(flux[i]) }
        var envelope = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius)
            let hi = min(n, i + radius + 1)
            let mean = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            envelope[i] = max(0, flux[i] - Float(mean))
        }
        let deviation = vDSP.standardDeviation(envelope)
        return deviation > 0 ? vDSP.divide(envelope, deviation) : envelope
    }

    // Beat period in frames: the envelope's strongest self-similarity between 60 and 200 BPM,
    // weighted toward ~120 BPM so a song isn't tracked at half or double its felt tempo.
    private static func tempoPeriod(_ envelope: [Float], frameSeconds: Double) -> Int? {
        let minLag = max(1, Int((60.0 / 200.0 / frameSeconds).rounded(.down)))
        let maxLag = Int((60.0 / 60.0 / frameSeconds).rounded(.up))
        guard envelope.count > maxLag * 2 else { return nil }
        var best: (lag: Int, score: Double)?
        envelope.withUnsafeBufferPointer { ep in
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(ep.baseAddress!, 1, ep.baseAddress! + lag, 1, &dot, vDSP_Length(envelope.count - lag))
                let bpm = 60 / (Double(lag) * frameSeconds)
                let prior = exp(-0.5 * pow(log2(bpm / 120), 2))
                let score = Double(dot) * prior
                if score > (best?.score ?? -.infinity) { best = (lag, score) }
            }
        }
        return best?.lag
    }

    // Dynamic-programming beat tracker: each frame's best score is its onset strength plus the
    // best predecessor half to two periods back, penalized for straying from the tempo. The chain
    // ending at the best frame in the last period is the beat sequence.
    private static func trackBeats(_ envelope: [Float], period: Int) -> [Int] {
        let n = envelope.count
        let maxBack = 2 * period
        let minBack = max(1, period / 2)
        let penalty: [Double] = (0...maxBack).map { d in
            d < minBack ? 0 : -tightness * pow(log(Double(d) / Double(period)), 2)
        }
        var cumulative = envelope.map(Double.init)
        var backlink = [Int](repeating: -1, count: n)
        for i in minBack..<n {
            var bestScore = -Double.infinity
            var bestIndex = -1
            for d in minBack...min(maxBack, i) {
                let score = cumulative[i - d] + penalty[d]
                if score > bestScore {
                    bestScore = score
                    bestIndex = i - d
                }
            }
            cumulative[i] += bestScore
            backlink[i] = bestIndex
        }
        let tailStart = max(0, n - period)
        var cursor = (tailStart..<n).max { cumulative[$0] < cumulative[$1] } ?? -1
        var beats: [Int] = []
        while cursor >= 0 {
            beats.append(cursor)
            cursor = backlink[cursor]
        }
        return beats.reversed()
    }

    // Level smoothed over ~0.4 s and mapped so this song's quiet end (10th percentile of audible
    // frames) is 0 and its loud end (95th) is 1 — a heavily mastered song and a soft one both use
    // the full size range, and an intro that explodes into the chorus reads as a big jump.
    private static func relativeLoudness(_ levelDb: [Float], frameSeconds: Double) -> [Float] {
        let n = levelDb.count
        let radius = max(1, Int(0.2 / frameSeconds))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(levelDb[i]) }
        let smoothed: [Float] = (0..<n).map { i in
            let lo = max(0, i - radius)
            let hi = min(n, i + radius + 1)
            return Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
        let audible = smoothed.filter { $0 > -60 }.sorted()
        guard audible.count > 10 else { return [Float](repeating: 0, count: n) }
        let quiet = audible[audible.count / 10]
        let loud = audible[audible.count * 95 / 100]
        let range = max(6, loud - quiet)
        return smoothed.map { min(1, max(0, ($0 - quiet) / range)) }
    }

    // Per beat, whether it's in a quiet stretch (pulse every other beat) — with hysteresis so a
    // single soft beat inside a loud section doesn't halve the pulse.
    private static func halfTimeFlags(_ beatLoudness: [Float]) -> [Bool] {
        var quiet = (beatLoudness.first ?? 0) < loudAbove
        return beatLoudness.map { level in
            if quiet, level > loudAbove { quiet = false }
            if quiet == false, level < quietBelow { quiet = true }
            return quiet
        }
    }
}
