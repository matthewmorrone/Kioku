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

    // Synthesizes the full listen-along track for a breakdown and writes it to a cache file,
    // returning the file URL. The cache key includes `sourceTextHash`, so re-opening Listen
    // for an unchanged breakdown reuses the existing file instead of re-synthesizing, while a
    // regenerated breakdown (different hash) renders fresh — any stale file(s) for this note
    // under an old hash are cleaned up so cache growth stays bounded to one track per note.
    // `onProgress` reports a 0...1 fraction after each segment for a progress bar.
    func renderAudio(
        for breakdown: SongBreakdown,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        let destination = Self.destinationURL(forNoteID: breakdown.noteID, sourceTextHash: breakdown.sourceTextHash)
        if FileManager.default.fileExists(atPath: destination.path) {
            await onProgress(1)
            return destination
        }
        Self.removeStaleCachedFiles(forNoteID: breakdown.noteID, keeping: destination)

        // Resolved once up front: a device missing either installed voice would otherwise
        // have AVSpeechSynthesizer silently substitute its default voice per-utterance,
        // defeating the whole point of switching languages — fail loudly instead.
        guard let japaneseVoice = AVSpeechSynthesisVoice(language: "ja-JP"),
              let englishVoice = AVSpeechSynthesisVoice(language: "en-US") else {
            throw SongListenRenderError.voiceUnavailable
        }

        let segments = SongListenScript.build(from: breakdown)
        guard segments.isEmpty == false else { throw SongListenRenderError.emptyScript }

        // Written under a distinct name (kept as ".caf" so AVAudioFile still infers the right
        // container) and moved into place only once complete, so a cancelled or interrupted
        // render never leaves a corrupt file at the real cache key for `renderAudio` to
        // wrongly treat as a valid cached track next time.
        let workingDestination = destination
            .deletingPathExtension()
            .appendingPathExtension("partial.caf")
        try? FileManager.default.removeItem(at: workingDestination)

        var audioFile: AVAudioFile?
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let voice = segment.language == .japanese ? japaneseVoice : englishVoice
            let buffers = try await synthesizeBuffers(for: segment, voice: voice)
            for buffer in buffers {
                if audioFile == nil {
                    audioFile = try AVAudioFile(forWriting: workingDestination, settings: buffer.format.settings)
                }
                try audioFile?.write(from: buffer)
            }
            if let silence = Self.silenceBuffer(matching: audioFile?.processingFormat, after: segment.kind) {
                try audioFile?.write(from: silence)
            }
            await onProgress(Double(index + 1) / Double(segments.count))
        }

        guard audioFile != nil else { throw SongListenRenderError.noAudioProduced }
        audioFile = nil // close the file handle before moving it into place
        try FileManager.default.moveItem(at: workingDestination, to: destination)
        return destination
    }

    // Synthesizes one segment's text into its raw PCM buffers via the given voice. `write`
    // invokes its callback repeatedly on a background queue as synthesis proceeds and once
    // more with a zero-length buffer to signal completion — that terminal call is what
    // resumes the continuation.
    private func synthesizeBuffers(for segment: SongListenSegment, voice: AVSpeechSynthesisVoice) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.voice = voice

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
    // Keying on `sourceTextHash` (mirroring SongBreakdownStore's own cache key) means a
    // regenerated breakdown gets a fresh filename rather than silently reusing stale audio.
    static func destinationURL(forNoteID noteID: UUID, sourceTextHash: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(noteID.uuidString)-\(sourceTextHash).caf")
    }

    // Removes any previously-cached listen tracks for this note other than `keeping` — e.g.
    // ones left behind by an earlier breakdown hash — so a note that's regenerated
    // repeatedly doesn't accumulate one audio file per past breakdown version.
    private static func removeStaleCachedFiles(forNoteID noteID: UUID, keeping: URL) {
        let dir = keeping.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefix = "\(noteID.uuidString)-"
        for url in entries where url != keeping && url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
