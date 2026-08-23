import AVFoundation
import Foundation

// Accumulates synthesized speech into a single audio file, one PCM buffer at a time.
// AVSpeechSynthesizer's write callback can fire from any thread, so this stays `nonisolated`
// and `@unchecked Sendable` rather than picking up the module's default MainActor isolation —
// every call into it happens serially from that one callback (SongListenAudioService never
// touches it from anywhere else), so there's no real concurrent access to guard against; the
// compiler just can't see that from the callback's type alone.
nonisolated final class SongListenAudioSink: @unchecked Sendable {
    private(set) var audioFile: AVAudioFile?
    private let destination: URL

    // `destination` is the working (not-yet-final) file path the caller will move into place
    // once every segment has been written.
    init(destination: URL) {
        self.destination = destination
    }

    // Lazily opens the file using the first buffer's own format — that's the synthesizer's
    // native PCM format, so no conversion is needed — then appends the buffer.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        if audioFile == nil {
            audioFile = try AVAudioFile(forWriting: destination, settings: buffer.format.settings)
        }
        try audioFile?.write(from: buffer)
    }

    // Silence inserted after a segment. Longer after a full sentence/translation (a line
    // boundary) than between a word and its definition, so the ear can tell "new line" apart
    // from "next word in the same line's breakdown" without any spoken cue.
    func writeSilence(after kind: SongListenSegmentKind) throws {
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
    }

    // Releases the file handle. Must be called before the underlying file is moved or renamed.
    func close() {
        audioFile = nil
    }
}
