import Foundation
import AVFoundation
@preconcurrency import Speech
import SwiftWhisperAlign

// The single "audio file → subtitle cues" service shared by EVERY import path (the single-file
// ReadView import and BulkImportRunner). Callers own their own note lifecycle / progress UI; this
// owns transcription. Because it's the only place transcription lives, fixing or adding an engine
// (e.g. Qwen3 vocal-stem isolation) happens once and applies everywhere.
enum AudioTranscriptionService {
    enum EngineError: LocalizedError {
        case whisperModelMissing
        case empty
        var errorDescription: String? {
            switch self {
            case .whisperModelMissing: return "Select a Whisper model to transcribe with Whisper."
            case .empty: return "No speech was recognized in the audio."
            }
        }
    }

    // Transcribes `url` with `engine`. `isolateVocals` (engine-independent) isolates the vocal stem
    // first when true — best for songs. `whisperModelURL` is only consulted for Whisper;
    // `contextualStrings` only for Apple Speech. `onProgress` is 0–1; `onStatus` is a human label.
    static func transcribe(
        url: URL,
        engine: TranscriptionEngine,
        isolateVocals: Bool,
        whisperModelURL: URL? = nil,
        contextualStrings: [String] = [],
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        switch engine {
        case .qwen3:
            return try await qwen3(url: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
        case .whisper:
            let work = try await inputURL(for: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
            let base = isolateVocals ? 0.5 : 0.0, span = isolateVocals ? 0.5 : 1.0
            return try await whisper(url: work, modelURL: whisperModelURL, onProgress: { f in onProgress?(base + f * span) })
        case .appleSpeech:
            let work = try await inputURL(for: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
            let base = isolateVocals ? 0.5 : 0.0, span = isolateVocals ? 0.5 : 1.0
            return try await appleSpeech(url: work, contextualStrings: contextualStrings, onProgress: { f in onProgress?(base + f * span) })
        }
    }

    // Qwen3-ASR. With isolation, runs on the isolated vocal stem (shared cache with alignment) —
    // clean vocals, not the mix, which is why it transcribes songs well. Without, on the raw mix
    // (fine for plain speech). First half of progress is isolation/decode.
    private static func qwen3(
        url: URL, isolateVocals: Bool,
        onProgress: (@Sendable (Double) -> Void)?, onStatus: (@Sendable (String) -> Void)?
    ) async throws -> [SubtitleCue] {
        let samples: [Float]
        let sampleRate: Int
        if isolateVocals {
            onStatus?("Isolating vocals…")
            samples = try await CTCForcedAligner.isolatedVocalStem(for: url, onProgress: { f in onProgress?(f * 0.5) })
            sampleRate = 44_100
        } else {
            onStatus?("Decoding audio…")
            samples = try await decodeMonoSamples(from: url, sampleRate: 16_000)
            sampleRate = 16_000
        }
        onStatus?(isolateVocals ? "Transcribing vocals…" : "Transcribing audio…")
        let base = isolateVocals ? 0.5 : 0.0, span = isolateVocals ? 0.5 : 1.0
        let segs = try await StemTranscriber.segments(
            stem: samples, sampleRate: sampleRate, pieceSec: 16, language: "Japanese",
            onFraction: { f in onProgress?(base + f * span) }
        )
        let cues = chunkCues(segs)
        if cues.isEmpty { throw EngineError.empty }
        return cues
    }

    // The file the URL-based engines (Whisper / Apple Speech) should transcribe: the isolated-stem
    // WAV when isolation is requested, else the original. Isolation populates the shared stem cache.
    private static func inputURL(
        for url: URL, isolateVocals: Bool,
        onProgress: (@Sendable (Double) -> Void)?, onStatus: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        guard isolateVocals else { return url }
        onStatus?("Isolating vocals…")
        _ = try await CTCForcedAligner.isolatedVocalStem(for: url, onProgress: { f in onProgress?(f * 0.5) })
        onStatus?("Transcribing vocals…")
        return VocalStemCache.stemWAVURL(for: url) ?? url
    }

    // Decodes any audio file to mono Float PCM at `sampleRate` via AVAssetReader (one-pass resample).
    private static func decodeMonoSamples(from url: URL, sampleRate: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(domain: "Kioku.Transcription", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track found in the file."])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "Kioku.Transcription", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not configure audio reader."])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "Kioku.Transcription", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Audio reader failed to start."])
        }
        var frames: [Float] = []
        while reader.status == .reading {
            guard let buf = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(buf) }
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let ptr, len > 0 else { continue }
            let count = len / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: count) { fptr in
                frames.append(contentsOf: UnsafeBufferPointer(start: fptr, count: count))
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Kioku.Transcription", code: 4,
                                          userInfo: [NSLocalizedDescriptionKey: "Audio decoding failed."])
        }
        return frames
    }

    // Whisper (GGML) — requires a downloaded model. Maps the provider's second-based segments to cues.
    private static func whisper(
        url: URL, modelURL: URL?, onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [SubtitleCue] {
        guard let modelURL else { throw EngineError.whisperModelMissing }
        let provider = SwiftWhisperTranscriptionProvider(modelURL: modelURL)
        let segments = try await provider.transcribe(url: url, onProgress: onProgress)
        var cues: [SubtitleCue] = []
        for seg in segments {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty == false else { continue }
            cues.append(SubtitleCue(index: cues.count + 1,
                                    startMs: max(0, Int((seg.start * 1000).rounded())),
                                    endMs: max(0, Int((seg.end * 1000).rounded())), text: t))
        }
        if cues.isEmpty { throw EngineError.empty }
        return cues
    }

    // Apple Speech (SFSpeechRecognizer) — system-provided, near-zero app memory. Chunks the file
    // (speech-active ranges, fixed fallback), recognizes each, retries finer on low yield, then
    // distributes line-level cues over the duration. Mirrors the single-file path's old behavior.
    private static func appleSpeech(
        url: URL, contextualStrings: [String], onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [SubtitleCue] {
        try await AudioTranscriptionHelpers.requestSpeechAuthorizationIfNeeded()
        let duration = try await AudioTranscriptionHelpers.audioDuration(for: url)
        var ranges = try await ReadView.makeSpeechActiveChunkRanges(for: url, maxChunkDuration: 12.0, overlap: 0.4)
        if ranges.isEmpty { ranges = try await ReadView.makeChunkRanges(for: url, chunkDuration: 12.0, overlap: 0.4) }

        var (bestTranscript, bestSegments) = try await applePass(url: url, ranges: ranges, contextualStrings: contextualStrings, onProgress: onProgress)
        if AudioTranscriptionHelpers.shouldRetryForLowYield(transcript: bestTranscript, durationSeconds: duration) {
            let retry = try await ReadView.makeChunkRanges(for: url, chunkDuration: 8.0, overlap: 0.8)
            let (rt, rs) = try await applePass(url: url, ranges: retry, contextualStrings: [], onProgress: onProgress)
            if rt.count > bestTranscript.count { bestTranscript = rt; bestSegments = rs }
        }
        guard bestTranscript.isEmpty == false else { throw EngineError.empty }
        let cues = AudioTranscriptionHelpers.makeLineLevelSubtitleCues(
            from: bestSegments, fallbackTranscript: bestTranscript, audioDurationSeconds: duration)
        if cues.isEmpty { throw EngineError.empty }
        return cues
    }

    // One Apple Speech pass over `ranges`: export each chunk, recognize it, accumulate the merged
    // transcript + all segments. A no-speech/error chunk is skipped (non-fatal), not aborted.
    private static func applePass(
        url: URL, ranges: [(start: TimeInterval, end: TimeInterval)],
        contextualStrings: [String], onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (String, [SFTranscriptionSegment]) {
        var transcript = ""
        var segments: [SFTranscriptionSegment] = []
        for (i, r) in ranges.enumerated() {
            do {
                let chunkURL = try await AudioTranscriptionHelpers.exportAudioChunk(from: url, start: r.start, end: r.end, index: i)
                defer { try? FileManager.default.removeItem(at: chunkURL) }
                let t = try await AudioTranscriptionHelpers.recognizeTranscription(from: chunkURL, contextualStrings: contextualStrings)
                segments.append(contentsOf: t.segments)
                let ct = t.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if ct.isEmpty == false { transcript = AudioTranscriptionHelpers.mergeChunkTranscript(transcript, ct) }
            } catch {
                // No-speech is expected on instrumental/silent chunks; ignore. Other errors are
                // non-fatal here — one bad chunk shouldn't abort the whole file.
            }
            onProgress?(Double(i + 1) / Double(max(1, ranges.count)))
        }
        return (transcript, segments)
    }

    // Maps StemTranscriber's per-chunk (start, end, text) tuples to sequential ms cues, dropping empties.
    private static func chunkCues(_ segs: [(start: Double, end: Double, text: String)]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for s in segs {
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty == false else { continue }
            cues.append(SubtitleCue(index: cues.count + 1,
                                    startMs: max(0, Int((s.start * 1000).rounded())),
                                    endMs: max(0, Int((s.end * 1000).rounded())), text: t))
        }
        return cues
    }
}
