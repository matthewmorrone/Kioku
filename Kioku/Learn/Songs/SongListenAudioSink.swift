import AVFoundation
import Foundation

// Accumulates the listen-along track — synthesized speech AND spliced-in song-audio clips —
// into a single audio file, one PCM buffer at a time. AVSpeechSynthesizer's write callback
// can fire from any thread, so this stays `nonisolated` and `@unchecked Sendable` rather than
// picking up the module's default MainActor isolation — every call into it happens serially
// (SongListenAudioService never touches it from two places at once), so there's no real
// concurrent access to guard against; the compiler just can't see that from the callback's
// type alone.
nonisolated final class SongListenAudioSink: @unchecked Sendable {
    private(set) var audioFile: AVAudioFile?
    private let destination: URL
    // Fixed up front rather than inferred from the first buffer written (the old behavior):
    // once clips from the song's own audio file entered the mix, "whichever format shows up
    // first" would make the output format depend on step ordering — a line with no matched
    // clip would open the file in the synthesizer's format, while one with a clip would open
    // it in the song's format. A stable target format means every buffer (speech or clip)
    // goes through the same conversion path, so the output is deterministic either way.
    private let targetFormat: AVAudioFormat

    // `destination` is the working (not-yet-final) file path the caller will move into place
    // once every segment has been written.
    init(destination: URL, targetFormat: AVAudioFormat) {
        self.destination = destination
        self.targetFormat = targetFormat
    }

    // Opens the file (lazily, on first write) in `targetFormat`, converting the incoming
    // buffer into that format first if it doesn't already match — true for song-audio clips
    // (their own file's sample rate/channel count) and, incidentally, for TTS buffers too if
    // a given voice's native format ever differs from `targetFormat`.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        if audioFile == nil {
            audioFile = try AVAudioFile(forWriting: destination, settings: targetFormat.settings)
        }
        guard buffer.format != targetFormat else {
            try audioFile?.write(from: buffer)
            return
        }
        let converted = try convert(buffer, to: targetFormat)
        try audioFile?.write(from: converted)
    }

    // Runs `buffer` through an AVAudioConverter into `format`. A fresh converter per call is
    // fine here — this runs a few dozen times per song (once per segment/clip), not per frame.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw SongListenRenderError.conversionFailed
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            throw SongListenRenderError.conversionFailed
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard suppliedInput == false else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw SongListenRenderError.conversionFailed }
        return output
    }

    // Silence inserted after a segment. Longer after a full sentence/translation (a line
    // boundary) than between a word and its definition, so the ear can tell "new line" apart
    // from "next word in the same line's breakdown" without any spoken cue.
    func writeSilence(after kind: SongListenSegmentKind) throws {
        let seconds: Double
        switch kind {
        case .sentence: seconds = 0.5
        case .translation: seconds = 0.7
        case .wordSurface: seconds = 0.15
        case .wordDefinition: seconds = 0.45
        }
        try writeSilence(seconds: seconds)
    }

    // Silence inserted after a song-audio clip, before its line's spoken breakdown begins —
    // a beat longer than the post-sentence gap so the sung line and its explanation don't run
    // together.
    func writeSilenceAfterClip() throws {
        try writeSilence(seconds: 0.6)
    }

    // Shared implementation behind the two public writeSilence(after:)/writeSilenceAfterClip()
    // entry points — writes a zeroed buffer of the given duration in the file's own format.
    private func writeSilence(seconds: Double) throws {
        guard let format = audioFile?.processingFormat else { return }
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        try audioFile?.write(from: buffer)
    }

    // Releases the file handle. Must be called before the underlying file is moved or renamed.
    func close() {
        audioFile = nil
    }
}
