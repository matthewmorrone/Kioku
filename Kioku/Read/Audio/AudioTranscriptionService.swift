import Foundation
import SwiftWhisperAlign

// The single "audio file → subtitle cues" service shared by EVERY import path (the single-file
// ReadView import and BulkImportRunner). Callers own their own note lifecycle / progress UI; this
// owns transcription. The engine is Apple's SpeechTranscriber (4.9% character error on FLEURS
// Japanese speech vs Qwen3-ASR's 11.6%, PR #101), so transcription exists only on iOS 26+ and
// callers hide it below that. Don't bring back SFSpeechRecognizer (90.7% character error on songs),
// Whisper (crashed on-device, commit 5e729ff) or an MLX model (it made MLX and its ~20 transitive
// packages the bulk of every build).
@available(iOS 26.0, *)
enum AudioTranscriptionService {
    enum EngineError: LocalizedError {
        case empty
        var errorDescription: String? {
            switch self {
            case .empty: return "No speech was recognized in the audio."
            }
        }
    }

    // Transcribes `url`. `isolateVocals` isolates the vocal stem first when true — best for songs.
    // `onProgress` is 0–1; `onStatus` is a human label.
    static func transcribe(
        url: URL,
        isolateVocals: Bool,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        // Keep on-device stemming + transcription running if the user backgrounds the app mid-run.
        let bg = BackgroundTaskHolder.begin("kioku.transcribe")
        defer { bg.endDetached() }
        let work = try await inputURL(for: url, isolateVocals: isolateVocals, onProgress: onProgress, onStatus: onStatus)
        let cues = try await AppleSpeechTranscription.transcribe(url: work, onStatus: onStatus)
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
}
