import AVFoundation
import Foundation
import os

// Renders a SongBreakdown into a single linear, exportable audio file: for each line, the
// sung clip from the song's own audio (when a matched time range is available), then the
// Japanese sentence, then the English gist, then every word's Japanese surface followed by
// its English definition — one line after another (see SongListenScript for the exact
// ordering). Synthesis alternates between a Japanese and an English AVSpeechSynthesisVoice
// — the best-quality (premium, else enhanced, else default) voice installed for each
// language — per same-language run *within* each segment (SongListenLanguageRuns), so the
// listener always hears each language spoken by a voice built for it ("code switching")
// instead of one voice skipping or mangling the other language's text.
//
// Runs entirely on-device via AVSpeechSynthesizer's buffer-based `write(_:toBufferCallback:)`
// — no network call, no API key, no per-request cost. Buffers (speech and song-clip alike)
// are streamed into a SongListenAudioSink with short silences between segments so the result
// is a normal, seekable, shareable file rather than a live-only utterance queue tied to this
// process.
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

    // Fixed output format for the whole track — see SongListenAudioSink's header comment for
    // why this can't just be inferred from whichever buffer happens to arrive first once song
    // clips are in the mix. Mono/44.1kHz matches what AVSpeechSynthesizer and most song audio
    // sources both convert into cleanly.
    private static let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    // Synthesizes the full listen-along track for a breakdown and writes it to a cache file,
    // returning the file plus its transcript cues. The cache key includes `sourceTextHash`
    // plus a signature of the clip inputs, so re-opening Listen for an unchanged breakdown AND
    // unchanged audio/cues reuses the existing file instead of re-rendering, while either
    // changing (regenerated breakdown, swapped audio attachment, re-aligned cues) renders
    // fresh — any stale file(s) for this note under an old key are cleaned up so cache growth
    // stays bounded to one track per note. A cache hit requires both the audio file AND its
    // cues sidecar to be present and readable — timing can only be recovered by
    // re-synthesizing, so a partial/older cache (e.g. from before cues were tracked at all) is
    // treated as a miss rather than silently returning a track with no transcript.
    // `onProgress` reports a 0...1 fraction after each step for a progress bar.
    //
    // `sourceAudioURL`/`lineRanges` are optional: pass both to splice in the sung clip before
    // each line's breakdown (mirrors the per-line ▶︎ button's own SongLineCueMatcher-derived
    // ranges, so the listener hears exactly what tapping that button would play). Omit either
    // (the defaults) to render narration-only, e.g. for a note with no audio attachment.
    func renderAudio(
        for breakdown: SongBreakdown,
        sourceAudioURL: URL? = nil,
        lineRanges: [Int: (startMs: Int, endMs: Int)] = [:],
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> SongListenRenderResult {
        let effectiveRanges = sourceAudioURL != nil ? lineRanges : [:]
        let destination = Self.destinationURL(
            forNoteID: breakdown.noteID,
            sourceTextHash: breakdown.sourceTextHash,
            clipsSignature: Self.clipsSignature(sourceAudioURL: sourceAudioURL, lineRanges: effectiveRanges)
        )
        let cuesDestination = Self.cuesURL(for: destination)
        if FileManager.default.fileExists(atPath: destination.path),
           let cachedCues = Self.loadCues(from: cuesDestination) {
            await onProgress(1)
            return SongListenRenderResult(url: destination, cues: cachedCues)
        }
        Self.removeStaleCachedFiles(forNoteID: breakdown.noteID, keeping: destination)

        // Resolved once up front: a device missing either installed voice would otherwise
        // have AVSpeechSynthesizer silently substitute its default voice per-utterance,
        // defeating the whole point of switching languages — fail loudly instead.
        guard let japaneseVoice = Self.preferredVoice(languageCode: "ja-JP"),
              let englishVoice = Self.preferredVoice(languageCode: "en-US") else {
            throw SongListenRenderError.voiceUnavailable
        }

        let steps = SongListenScript.build(from: breakdown, lineRanges: effectiveRanges)
        guard steps.isEmpty == false else { throw SongListenRenderError.emptyScript }

        // Written under a distinct, per-attempt name (kept as ".caf" so AVAudioFile still
        // infers the right container) and moved into place only once complete, so a
        // cancelled or interrupted render never leaves a corrupt file at the real cache key
        // for `renderAudio` to wrongly treat as a valid cached track next time. The name is
        // unique per call (not just per note+hash) because Task cancellation is cooperative:
        // a caller that cancels one render and immediately starts a replacement (e.g.
        // SongListenStore.retry) can leave the cancelled render still writing for a while —
        // sharing one working path would let the two concurrently append to the same open
        // file. A losing attempt's stale move onto `destination` at the end simply throws
        // (the winner already moved its own file there first) and is dropped by the caller.
        let workingDestination = destination
            .deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString).partial.caf")

        let sink = SongListenAudioSink(destination: workingDestination, targetFormat: Self.targetFormat)
        var cues: [SubtitleCue] = []
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            switch step {
            case .speech(let segment):
                let startMs = sink.elapsedMs
                let runs = SongListenLanguageRuns.split(segment.text, defaultLanguage: segment.language)
                for (runIndex, run) in runs.enumerated() {
                    if runIndex > 0 { try sink.writeSilenceBetweenVoices() }
                    let voice = run.language == .japanese ? japaneseVoice : englishVoice
                    try await synthesizeAndWrite(text: run.text, voice: voice, sink: sink)
                    try sink.finishSegment()
                }
                cues.append(SubtitleCue(index: cues.count, startMs: startMs, endMs: sink.elapsedMs, text: segment.text))
                try sink.writeSilence(after: segment.kind)
            case .clip(_, let startMs, let endMs):
                guard let sourceAudioURL else { continue }
                let buffer = try readClip(from: sourceAudioURL, startMs: startMs, endMs: endMs)
                try sink.write(buffer)
                try sink.finishSegment()
                try sink.writeSilenceAfterClip()
            }
            await onProgress(Double(index + 1) / Double(steps.count))
        }

        guard sink.audioFile != nil else { throw SongListenRenderError.noAudioProduced }
        sink.close()
        try FileManager.default.moveItem(at: workingDestination, to: destination)
        try Self.saveCues(cues, to: cuesDestination)
        return SongListenRenderResult(url: destination, cues: cues)
    }

    // Synthesizes one run of text via the given voice and streams every PCM buffer straight into
    // `sink` as it arrives, rather than collecting them into an array to hand back — that
    // would require sending a batch of AVAudioPCMBuffers across the continuation's isolation
    // boundary, which is exactly the data race the compiler flags. `write`'s callback fires
    // repeatedly on a background queue and once more with a zero-length buffer to signal
    // completion; an `OSAllocatedUnfairLock`-guarded flag makes sure exactly one of those
    // calls resumes the continuation, since a write failure resuming early wouldn't stop the
    // synthesizer from calling back again afterward.
    private func synthesizeAndWrite(text: String, voice: AVSpeechSynthesisVoice, sink: SongListenAudioSink) async throws {
        let utterance = AVSpeechUtterance(string: text)
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

    // Reads the [startMs, endMs) slice of the song's own audio file as one PCM buffer, in
    // that file's native format (SongListenAudioSink converts it into the track's target
    // format). Clamped to the file's actual length in case a cue's endMs slightly overruns
    // the source (SRT timing drift) rather than throwing on an out-of-range read.
    private func readClip(from url: URL, startMs: Int, endMs: Int) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, AVAudioFramePosition((Double(startMs) / 1000) * sampleRate))
        let endFrame = min(file.length, AVAudioFramePosition((Double(endMs) / 1000) * sampleRate))
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw SongListenRenderError.clipReadFailed
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        return buffer
    }

    // Picks the best-quality installed voice for a language: premium, else enhanced, else
    // whatever `AVSpeechSynthesisVoice(language:)` resolves to (the plain system default also
    // used everywhere else word audio plays in this app). Premium/enhanced voices sound
    // distinctly more natural and, being a deliberate download rather than always-present,
    // read as a different voice than the app's other TTS call sites — appropriate for a
    // longer narrated track where voice quality matters more than for a one-word tap-to-hear.
    private static func preferredVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        if let best = candidates.max(by: { qualityRank($0.quality) < qualityRank($1.quality) }) {
            return best
        }
        return AVSpeechSynthesisVoice(language: languageCode)
    }

    // Orders voice quality tiers so `max(by:)` above picks premium over enhanced over default.
    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 2
        case .enhanced: return 1
        case .default: return 0
        @unknown default: return 0
        }
    }

    // Cache location: derived, regenerable content lives under Library/Caches so it's swept
    // by the existing "Clear Caches" action (CachesCleaner) and never backed up to iCloud.
    // Keying on `sourceTextHash` plus `clipsSignature` (mirroring SongBreakdownStore's own
    // cache-key approach) means a regenerated breakdown, a swapped audio attachment, or a
    // re-aligned cue set each get a fresh filename rather than silently reusing a stale track.
    // `renderVersion` is part of the name so a change to how the track is synthesized
    // (e.g. per-run voice switching) invalidates tracks rendered the old way instead of
    // replaying them from cache.
    static func destinationURL(forNoteID noteID: UUID, sourceTextHash: String, clipsSignature: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(noteID.uuidString)-\(sourceTextHash)-\(clipsSignature)-\(renderVersion).caf")
    }

    // Bump when synthesis output changes shape for the same inputs (see destinationURL).
    private static let renderVersion = "r2"

    // Folds the clip inputs (which audio file, and every line's matched range within it) into
    // one short signature for the cache key. "noaudio" when there's no attachment, so a note
    // that never had audio doesn't churn cache entries as this string's shape changes. Not
    // private: SongListenStore reuses it to build the same key so it knows when a note's clip
    // inputs (not just its breakdown text) have changed enough to warrant a fresh render.
    static func clipsSignature(sourceAudioURL: URL?, lineRanges: [Int: (startMs: Int, endMs: Int)]) -> String {
        guard let sourceAudioURL else { return "noaudio" }
        var hasher = Hasher()
        hasher.combine(sourceAudioURL.path)
        for (lineIndex, range) in lineRanges.sorted(by: { $0.key < $1.key }) {
            hasher.combine(lineIndex)
            hasher.combine(range.startMs)
            hasher.combine(range.endMs)
        }
        return String(UInt(bitPattern: hasher.finalize()))
    }

    // Sidecar JSON holding the transcript cues for `audioURL`, alongside it under the same
    // note-and-hash-derived name so `removeStaleCachedFiles`'s prefix sweep already cleans it
    // up along with the audio file it describes.
    private static func cuesURL(for audioURL: URL) -> URL {
        let base = audioURL.deletingPathExtension().lastPathComponent
        return audioURL.deletingLastPathComponent().appendingPathComponent("\(base).cues.json")
    }

    // Reads a cues sidecar back, if present and decodable. `nil` (rather than throwing) on
    // any failure — a missing/corrupt sidecar just means "not a cache hit", handled by the
    // caller falling back to a fresh render.
    private static func loadCues(from url: URL) -> [SubtitleCue]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SubtitleCue].self, from: data)
    }

    // Writes the freshly-rendered cues alongside the audio file, atomically so a reader never
    // observes a half-written sidecar.
    private static func saveCues(_ cues: [SubtitleCue], to url: URL) throws {
        let data = try JSONEncoder().encode(cues)
        try data.write(to: url, options: .atomic)
    }

    // Removes any previously-cached listen tracks (and their cues sidecars) for this note
    // other than `keeping` — e.g. ones left behind by an earlier breakdown hash — so a note
    // that's regenerated repeatedly doesn't accumulate one audio file per past breakdown
    // version.
    private static func removeStaleCachedFiles(forNoteID noteID: UUID, keeping: URL) {
        let dir = keeping.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefix = "\(noteID.uuidString)-"
        for url in entries where url != keeping && url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
