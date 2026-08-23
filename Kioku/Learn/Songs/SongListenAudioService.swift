import AVFoundation
import Foundation

// Renders a SongBreakdown into a single linear, exportable audio file: for each line, the
// Japanese sentence, then the English gist, then every word's Japanese surface followed by
// its English definition — one line after another (see SongListenScript for the exact
// ordering). Synthesis alternates between a Japanese and an English AVSpeechSynthesisVoice
// per segment, so the listener always hears each language spoken by a voice built for it
// ("code switching") instead of one voice mangling the other language's text.
//
// Runs entirely on-device via AVSpeechSynthesizer's buffer-based `write(_:toBufferCallback:)`
// — no network call, no API key, no per-request cost. Buffers are appended into one
// AVAudioFile with short silences between segments so the result is a normal, seekable,
// shareable file rather than a live-only utterance queue tied to this process.
final class SongListenAudioService {
    // A fresh synthesizer per instance — AVSpeechSynthesizer.write callbacks interleave if
    // the same instance drives two concurrent renders, and a single instance can only run
    // one synthesis at a time in any case.
    private let synthesizer = AVSpeechSynthesizer()
    private let japaneseVoice = AVSpeechSynthesisVoice(language: "ja-JP")
    private let englishVoice = AVSpeechSynthesisVoice(language: "en-US")

    // Synthesizes the full listen-along track for a breakdown and writes it to a cache file,
    // returning the file URL. Re-rendering the same note overwrites its previous file — the
    // breakdown (and therefore the script) is the only input, so there's nothing to keep two
    // versions of. `onProgress` reports a 0...1 fraction after each segment for a progress bar.
    func renderAudio(
        for breakdown: SongBreakdown,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        let segments = SongListenScript.build(from: breakdown)
        guard segments.isEmpty == false else { throw SongListenRenderError.emptyScript }

        let destination = Self.destinationURL(forNoteID: breakdown.noteID)
        try? FileManager.default.removeItem(at: destination)

        var audioFile: AVAudioFile?
        for (index, segment) in segments.enumerated() {
            let buffers = try await synthesizeBuffers(for: segment)
            for buffer in buffers {
                if audioFile == nil {
                    audioFile = try AVAudioFile(forWriting: destination, settings: buffer.format.settings)
                }
                try audioFile?.write(from: buffer)
            }
            if let silence = Self.silenceBuffer(matching: audioFile?.processingFormat, after: segment.kind) {
                try audioFile?.write(from: silence)
            }
            await onProgress(Double(index + 1) / Double(segments.count))
        }

        guard audioFile != nil else { throw SongListenRenderError.noAudioProduced }
        return destination
    }

    // Synthesizes one segment's text into its raw PCM buffers via the language-appropriate
    // voice. `write` invokes its callback repeatedly on a background queue as synthesis
    // proceeds and once more with a zero-length buffer to signal completion — that terminal
    // call is what resumes the continuation.
    private func synthesizeBuffers(for segment: SongListenSegment) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.voice = segment.language == .japanese ? japaneseVoice : englishVoice

        return try await withCheckedThrowingContinuation { continuation in
            var buffers: [AVAudioPCMBuffer] = []
            synthesizer.write(utterance) { audioBuffer in
                guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else {
                    continuation.resume(throwing: SongListenRenderError.noAudioProduced)
                    return
                }
                if pcmBuffer.frameLength == 0 {
                    continuation.resume(returning: buffers)
                } else {
                    buffers.append(pcmBuffer)
                }
            }
        }
    }

    // Silence inserted after a segment. Longer after a full sentence/translation (a line
    // boundary) than between a word and its definition, so the ear can tell "new line" apart
    // from "next word in the same line's breakdown" without any spoken cue.
    private static func silenceBuffer(matching format: AVAudioFormat?, after kind: SongListenSegmentKind) -> AVAudioPCMBuffer? {
        guard let format else { return nil }
        let seconds: Double
        switch kind {
        case .sentence: seconds = 0.5
        case .translation: seconds = 0.7
        case .wordSurface: seconds = 0.15
        case .wordDefinition: seconds = 0.45
        }
        let frameCount = AVAudioFrameCount(format.sampleRate * seconds)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        return buffer
    }

    // Cache location: derived, regenerable content lives under Library/Caches so it's swept
    // by the existing "Clear Caches" action (CachesCleaner) and never backed up to iCloud.
    // One file per note, named by noteID, so re-rendering just overwrites in place.
    static func destinationURL(forNoteID noteID: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(noteID.uuidString).caf")
    }
}
