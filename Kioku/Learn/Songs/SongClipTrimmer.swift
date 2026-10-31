import AVFoundation
import Foundation

// Trims dead air off a sung clip using the vocal stem's waveform. Split out of
// SongLiveListenController, which only needs the resulting range.
nonisolated enum SongClipTrimmer {
    // Tightens a clip's boundaries to the audible singing within it, reading from the isolated
    // vocal stem's own file (`stemTrimURL`) — never the raw mix, whose continuous backing music
    // makes "silence" undetectable. SongLineCueMatcher's checkpoint-based tightening (applied
    // upstream) already uses real per-character alignment timestamps; this adds a waveform-based
    // pass for whatever slack remains.
    //
    // Works on short RMS windows rather than individual sample peaks, and thresholds each window
    // against a floor *relative to this clip's own peak* rather than one fixed absolute level: the
    // stem's separation artifacts (a low-level hiss/breath/reverb tail left behind by the ML
    // source-separation model) routinely sit above a fixed floor like 0.02 well past where the
    // actual singing stops. A peak-relative floor clears that residue even when the clip itself is
    // quietly sung. The trailing edge additionally requires a short run of consecutive loud windows
    // (not just one) before it counts as "the singing is still going", so a single artifact blip in
    // the reverb tail doesn't drag the cut out to it.
    //
    // Crops to that span with a small fixed pad kept on each side so a genuinely quiet onset (e.g.
    // unvoiced す/し) isn't shaved into the following attack. Falls back to the untrimmed range on
    // any read failure, or when there's nothing to trim toward (the whole span is at/under the
    // floor).
    static func tightenedRange(stemURL: URL, startMs: Int, endMs: Int) -> (startMs: Int, endMs: Int) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: stemURL)
        } catch {
            AppLog.error(.audioPlayback, "vocal stem unreadable, clip left untrimmed: \(error)")
            return (startMs, endMs)
        }
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, AVAudioFramePosition((Double(startMs) / 1000) * sampleRate))
        let endFrame = min(file.length, AVAudioFramePosition((Double(endMs) / 1000) * sampleRate))
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return (startMs, endMs)
        }
        file.framePosition = startFrame
        do {
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            AppLog.error(.audioPlayback, "vocal stem read failed, clip left untrimmed: \(error)")
            return (startMs, endMs)
        }
        guard let channelData = buffer.floatChannelData else { return (startMs, endMs) }
        let totalFrames = Int(buffer.frameLength)
        guard totalFrames > 0 else { return (startMs, endMs) }
        let channelCount = Int(buffer.format.channelCount)
        let padFrames = Int(sampleRate * 0.02) // 20ms

        let windowSize = max(1, Int(sampleRate * 0.015))
        // RMS of the loudest channel over a ~15ms window starting at `frame` — a window
        // instead of a single sample so a lone spike (or a lone dropout) can't flip the
        // loud/quiet call on its own.
        func windowRMS(atFrame frame: Int) -> Float {
            let end = min(totalFrames, frame + windowSize)
            var bestSumSquares: Float = 0
            for channel in 0..<channelCount {
                var sumSquares: Float = 0
                let data = channelData[channel]
                for i in frame..<end {
                    sumSquares += data[i] * data[i]
                }
                bestSumSquares = max(bestSumSquares, sumSquares)
            }
            return (Float(end - frame) > 0) ? (bestSumSquares / Float(end - frame)).squareRoot() : 0
        }

        let windowStarts = stride(from: 0, to: totalFrames, by: windowSize).map { $0 }
        let windowRMSValues = windowStarts.map { windowRMS(atFrame: $0) }
        guard let peakRMS = windowRMSValues.max(), peakRMS > 0 else { return (startMs, endMs) }
        let threshold = max(peakRMS * 0.15, 0.006)
        let minSustainedWindows = 2

        // Whether a run of at least `minSustainedWindows` consecutive loud windows starts at
        // `index` — a single loud window (a stray separation-artifact blip) doesn't count.
        func isSustainedLoud(from index: Int) -> Bool {
            guard windowRMSValues.indices.contains(index) else { return false }
            var count = 0
            var i = index
            while i < windowRMSValues.count, windowRMSValues[i] >= threshold {
                count += 1
                if count >= minSustainedWindows { return true }
                i += 1
            }
            return count >= minSustainedWindows
        }

        var firstLoudWindow = windowRMSValues.firstIndex { $0 >= threshold } ?? windowRMSValues.count
        while firstLoudWindow < windowRMSValues.count, isSustainedLoud(from: firstLoudWindow) == false {
            firstLoudWindow += 1
        }
        var lastLoudWindow = -1
        for index in stride(from: windowRMSValues.count - 1, through: 0, by: -1) where windowRMSValues[index] >= threshold {
            let runStart = max(0, index - minSustainedWindows + 1)
            if isSustainedLoud(from: runStart) {
                lastLoudWindow = index
                break
            }
        }
        guard firstLoudWindow < windowRMSValues.count, lastLoudWindow >= 0, firstLoudWindow <= lastLoudWindow else {
            return (startMs, endMs)
        }

        let firstLoudFrame = windowStarts[firstLoudWindow]
        let lastLoudFrame = min(totalFrames - 1, windowStarts[lastLoudWindow] + windowSize - 1)
        let trimStartFrame = max(0, firstLoudFrame - padFrames)
        let trimEndFrame = min(totalFrames, lastLoudFrame + padFrames)
        let tightStartMs = startMs + Int(Double(trimStartFrame) / sampleRate * 1000)
        let tightEndMs = startMs + Int(Double(trimEndFrame) / sampleRate * 1000)
        guard tightEndMs > tightStartMs else { return (startMs, endMs) }
        return (tightStartMs, tightEndMs)
    }
}
