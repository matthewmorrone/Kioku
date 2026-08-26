import AVFoundation
import Foundation

// Accumulates synthesized speech into a single audio file, one PCM buffer at a time.
// AVSpeechSynthesizer's write callback can fire from any thread, so this stays `nonisolated`
// and `@unchecked Sendable` rather than picking up the module's default MainActor isolation —
// every call into it happens serially from that one callback (SongListenAudioService never
// touches it from anywhere else), so there's no real concurrent access to guard against; the
// compiler just can't see that from the callback's type alone.
//
// Every accepted buffer is held back by one: `write(_:)` only ever flushes the *previous*
// buffer to disk, so that the true last buffer of a segment — identified by the caller via
// `finishSegment()` — can be tail-faded before it's written. Without this, the cut from live
// speech straight into the inserted silence gap is an abrupt waveform discontinuity: an
// audible click at every one of a song's segment boundaries, which is what reads as constant
// static/crackle across a whole track. The first buffer of each segment is head-faded the
// same way, for the same reason at the opposite edge.
nonisolated final class SongListenAudioSink: @unchecked Sendable {
    private(set) var audioFile: AVAudioFile?
    private let destination: URL
    private var pendingBuffer: AVAudioPCMBuffer?
    private var isSegmentStart = true
    private var converter: AVAudioConverter?

    // Total frames committed to the logical track so far, including whatever's still held in
    // `pendingBuffer` — this is what SongListenAudioService reads (via `elapsedMs`) to stamp
    // each script segment with its start/end offset for the transcript highlight cues, so it
    // must reflect audio that's been accepted even if it hasn't physically hit disk yet.
    private(set) var totalFrameCount: AVAudioFramePosition = 0

    var elapsedMs: Int {
        let sampleRate = audioFile?.processingFormat.sampleRate ?? 0
        guard sampleRate > 0 else { return 0 }
        return Int((Double(totalFrameCount) / sampleRate * 1000).rounded())
    }

    // Length of the fade applied at each segment's head/tail — short enough to be inaudible
    // as a volume dip, long enough to smooth the discontinuity (a few ms at TTS sample rates).
    private static let fadeFrameCount = 256

    // `destination` is the working (not-yet-final) file path the caller will move into place
    // once every segment has been written.
    init(destination: URL) {
        self.destination = destination
    }

    // Accepts one synthesized buffer. Lazily opens the file using the first buffer's own
    // format — that's the synthesizer's native PCM format, so no conversion is needed for
    // same-voice buffers — then converts any later buffer whose format doesn't match (e.g. a
    // different voice's native sample rate) before it's queued for writing.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        if audioFile == nil {
            audioFile = try AVAudioFile(forWriting: destination, settings: buffer.format.settings)
        }
        guard let processingFormat = audioFile?.processingFormat else { return }
        let matched = try convertIfNeeded(buffer, to: processingFormat)
        if isSegmentStart {
            applyFade(to: matched, frames: Self.fadeFrameCount, direction: .in)
            isSegmentStart = false
        }
        try flushPending()
        pendingBuffer = matched
        totalFrameCount += AVAudioFramePosition(matched.frameLength)
    }

    // Called once a segment's speech is fully written (all of AVSpeechSynthesizer's callbacks
    // for that utterance have fired). Fades the segment's true last buffer — still held in
    // `pendingBuffer` — before flushing it, and arms the next `write(_:)` call to head-fade,
    // so every segment starts and ends at (near-)silence instead of cutting abruptly.
    func finishSegment() throws {
        if let buffer = pendingBuffer {
            applyFade(to: buffer, frames: Self.fadeFrameCount, direction: .out)
        }
        try flushPending()
        isSegmentStart = true
    }

    // Silence inserted after a segment. Longer after a full sentence/translation (a line
    // boundary) than between a word and its definition, so the ear can tell "new line" apart
    // from "next word in the same line's breakdown" without any spoken cue.
    func writeSilence(after kind: SongListenSegmentKind) throws {
        try flushPending()
        guard let format = audioFile?.processingFormat else { return }
        let seconds: Double
        switch kind {
        case .sentence: seconds = 0.5
        case .translation: seconds = 0.7
        case .wordSurface: seconds = 0.15
        case .wordDefinition: seconds = 0.45
        }
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        try audioFile?.write(from: buffer)
        totalFrameCount += AVAudioFramePosition(frameCount)
    }

    // Releases the file handle. Must be called before the underlying file is moved or renamed.
    func close() {
        try? flushPending()
        audioFile = nil
    }

    // Writes out whatever buffer is currently held back, if any. Called before queuing a new
    // buffer, before inserting silence, and on close — every point where a not-yet-final
    // pending buffer must actually reach disk.
    private func flushPending() throws {
        guard let buffer = pendingBuffer else { return }
        pendingBuffer = nil
        try audioFile?.write(from: buffer)
    }

    // Converts `buffer` into `format` when its own format differs from the file's fixed
    // format (established from the very first buffer written). The two voices driving this
    // sink can have different native sample rates, and AVAudioFile.write(from:) requires an
    // exact format match — without this, a device where the two don't happen to agree would
    // either throw mid-render or (depending on the mismatch) write technically-valid frames
    // that decode back out sounding warped, which reads as "staticky" just the same.
    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else { return buffer }
        var error: NSError?
        var delivered = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return outBuffer
    }

    private enum FadeDirection { case `in`, out }

    // Applies a linear gain ramp to `buffer`'s first or last `frames` samples, in place.
    // AVSpeechSynthesizer's write callback has always delivered Float32 buffers in practice,
    // but int16 is handled too rather than silently skipping the fade on an unexpected format.
    private func applyFade(to buffer: AVAudioPCMBuffer, frames: Int, direction: FadeDirection) {
        let frameCount = Int(buffer.frameLength)
        let fadeLength = min(frames, frameCount)
        guard fadeLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        // Linear ramp value for sample offset `i` within the fade window: 0 at the silent
        // edge, approaching 1 at the edge bordering full-volume audio.
        func gain(at i: Int) -> Float {
            switch direction {
            case .in: return Float(i) / Float(fadeLength)
            case .out: return Float(fadeLength - i - 1) / Float(fadeLength)
            }
        }
        let base = direction == .in ? 0 : frameCount - fadeLength
        if let floatData = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = floatData[channel]
                for i in 0..<fadeLength {
                    samples[base + i] *= gain(at: i)
                }
            }
        } else if let intData = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = intData[channel]
                for i in 0..<fadeLength {
                    samples[base + i] = Int16(Float(samples[base + i]) * gain(at: i))
                }
            }
        }
    }
}
