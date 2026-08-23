import AVFoundation
import Foundation
import os

// Renders a SongBreakdown into a single linear, exportable audio file: for each line, the
// Japanese sentence, then the English gist, then every word's Japanese surface followed by
// its English definition — one line after another (see SongListenScript for the exact
// ordering). Synthesis alternates between a Japanese and an English AVSpeechSynthesisVoice
// per segment, so the listener always hears each language spoken by a voice built for it
// ("code switching") instead of one voice mangling the other language's text.
//
// Runs entirely on-device via AVSpeechSynthesizer's buffer-based `write(_:toBufferCallback:)`
// — no network call, no API key, no per-request cost. Buffers are streamed into a
// SongListenAudioSink with short silences between segments so the result is a normal,
// seekable, shareable file rather than a live-only utterance queue tied to this process.
//
// Marked `nonisolated`: this is a pure background worker with no UI ties, and
// AVSpeechSynthesizer's write callback fires off whatever thread AVFoundation chooses — opting
// out of the module's default MainActor isolation keeps that callback (and the buffers it
// hands over) from ever needing to cross onto the main actor, which is exactly the "sending"
// data-race the compiler would otherwise (rightly) reject.
nonisolated final class SongListenAudioService {
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

        let sink = SongListenAudioSink(destination: workingDestination)
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let voice = segment.language == .japanese ? japaneseVoice : englishVoice
            try await synthesizeAndWrite(segment: segment, voice: voice, sink: sink)
            try sink.writeSilence(after: segment.kind)
            await onProgress(Double(index + 1) / Double(segments.count))
        }

        guard sink.audioFile != nil else { throw SongListenRenderError.noAudioProduced }
        sink.close()
        try FileManager.default.moveItem(at: workingDestination, to: destination)
        return destination
    }

    // Synthesizes one segment via the given voice and streams every PCM buffer straight into
    // `sink` as it arrives, rather than collecting them into an array to hand back — that
    // would require sending a batch of AVAudioPCMBuffers across the continuation's isolation
    // boundary, which is exactly the data race the compiler flags. `write`'s callback fires
    // repeatedly on a background queue and once more with a zero-length buffer to signal
    // completion; an `OSAllocatedUnfairLock`-guarded flag makes sure exactly one of those
    // calls resumes the continuation, since a write failure resuming early wouldn't stop the
    // synthesizer from calling back again afterward.
    private func synthesizeAndWrite(segment: SongListenSegment, voice: AVSpeechSynthesisVoice, sink: SongListenAudioSink) async throws {
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.voice = voice
        let hasResumed = OSAllocatedUnfairLock(initialState: false)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            synthesizer.write(utterance) { audioBuffer in
                guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else { return }
                if pcmBuffer.frameLength == 0 {
                    hasResumed.withLock { resumed in
                        guard resumed == false else { return }
                        resumed = true
                        continuation.resume(returning: ())
                    }
                    return
                }
                do {
                    try sink.write(pcmBuffer)
                } catch {
                    hasResumed.withLock { resumed in
                        guard resumed == false else { return }
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
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
