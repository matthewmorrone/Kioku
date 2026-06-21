import AVFoundation
import Foundation

// A downsampled peak-amplitude envelope of an audio file, used to draw the scrubbable waveform in
// the alignment editor. Computed once per audio — preferentially from the ISOLATED VOCAL STEM,
// where onsets/offsets read unmistakably (the full mix buries them under drums/bass) — then sliced
// per line. Peaks are normalized 0…1; one entry per `bucketMs` of audio.
struct WaveformEnvelope: Sendable {
    // Normalized peak amplitude in 0…1, one entry per time bucket.
    let peaks: [Float]
    // Milliseconds of audio represented by each bucket.
    let bucketMs: Double

    var durationMs: Int { Int((Double(peaks.count) * bucketMs).rounded()) }

    // Peak amplitude (0…1) for the bucket covering `ms`, or 0 out of range. Used by the renderer to
    // sample one column at a time.
    func peak(atMs ms: Double) -> Float {
        guard bucketMs > 0 else { return 0 }
        let i = Int(ms / bucketMs)
        return peaks.indices.contains(i) ? peaks[i] : 0
    }

    // Decodes `url` into a mono peak envelope at ~`bucketMs` resolution. Reads 32-bit float mono at
    // a modest sample rate (an envelope needs no fidelity), tracking max |sample| per bucket, then
    // normalizes so the loudest bucket is 1.0. Returns nil if the file can't be read. `nonisolated`
    // so the heavy decode runs off the main actor (the project stamps @MainActor by default).
    nonisolated static func load(url: URL, bucketMs: Double = 12) async -> WaveformEnvelope? {
        let sampleRate = 16_000
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let bucketSamples = max(1, Int(Double(sampleRate) * bucketMs / 1000.0))
        var peaks: [Float] = []
        var curMax: Float = 0
        var curCount = 0
        var globalMax: Float = 0

        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { CMSampleBufferInvalidate(sb); continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>? = nil
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
                  let dataPtr, length > 0 else { CMSampleBufferInvalidate(sb); continue }
            let count = length / MemoryLayout<Float>.size
            dataPtr.withMemoryRebound(to: Float.self, capacity: count) { fp in
                for i in 0..<count {
                    let v = abs(fp[i])
                    if v > curMax { curMax = v }
                    curCount += 1
                    if curCount >= bucketSamples {
                        peaks.append(curMax)
                        if curMax > globalMax { globalMax = curMax }
                        curMax = 0
                        curCount = 0
                    }
                }
            }
            CMSampleBufferInvalidate(sb)
        }
        if curCount > 0 {
            peaks.append(curMax)
            if curMax > globalMax { globalMax = curMax }
        }
        guard peaks.isEmpty == false, globalMax > 0 else { return nil }
        let inv = 1.0 / globalMax
        for i in peaks.indices { peaks[i] = min(1, peaks[i] * inv) }
        return WaveformEnvelope(peaks: peaks, bucketMs: bucketMs)
    }
}
