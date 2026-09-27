import Foundation
import AVFoundation
import SwiftWhisperAlign

// The single "audio file → subtitle cues" service shared by EVERY import path (the single-file
// ReadView import and BulkImportRunner). Callers own their own note lifecycle / progress UI; this
// owns transcription. Because it's the only place transcription lives, fixing or adding an engine
// (e.g. Qwen3 vocal-stem isolation) happens once and applies everywhere.
enum AudioTranscriptionService {
    enum EngineError: LocalizedError {
        case empty
        var errorDescription: String? {
            switch self {
            case .empty: return "No speech was recognized in the audio."
            }
        }
    }

    // Transcribes `url` with `engine`. `isolateVocals` (engine-independent) isolates the vocal stem
    // first when true — best for songs. `onProgress` is 0–1; `onStatus` is a human label.
    static func transcribe(
        url: URL,
        engine: TranscriptionEngine,
        isolateVocals: Bool,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        // Keep on-device stemming + transcription running if the user backgrounds the app mid-run.
        let bg = BackgroundTaskHolder.begin("kioku.transcribe")
        defer { bg.endDetached() }
        switch engine {
        case .qwen3:
            return try await qwen3(url: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
        case .appleTranscriber:
            guard #available(iOS 26.0, *) else {
                return try await qwen3(url: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
            }
            let work = try await inputURL(for: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
            let cues = try await AppleSpeechTranscription.transcribe(url: work, onStatus: onStatus)
            if cues.isEmpty { throw EngineError.empty }
            return cues
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

    // The file SpeechTranscriber should transcribe: the isolated-stem
    // WAV when isolation is requested, else the original. Isolation populates the shared stem cache.
    private static func inputURL(
        for url: URL, isolateVocals: Bool,
        onProgress: (@Sendable (Double) -> Void)?, onStatus: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        guard isolateVocals else { return url }
        onStatus?("Isolating vocals…")
        _ = try await CTCForcedAligner.isolatedVocalStem(for: url, onProgress: { f in onProgress?(f * 0.5) })
        onStatus?("Transcribing vocals…")
        return VocalStemCache.playableStemURL(for: url) ?? url
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
