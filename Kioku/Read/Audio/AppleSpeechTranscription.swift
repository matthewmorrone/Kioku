import Foundation
import AVFoundation
import Speech

// Apple's on-device SpeechTranscriber (SpeechAnalyzer, iOS 26+) as a transcription engine: audio
// file → timed subtitle cues. On 30 FLEURS Japanese read-speech clips (2026-09-23) it scored 4.9%
// character error vs Qwen3-ASR 0.6B's 11.6%, and ran ~17× faster; on sung vocals both are poor.
// Apple manages the Japanese model: the first use downloads it through AssetInventory.
@available(iOS 26.0, *)
enum AppleSpeechTranscription {
    static let locale = Locale(identifier: "ja_JP")

    // Transcribes `url` into one cue per recognized phrase, timed from the analyzer's own ranges.
    static func transcribe(url: URL, onStatus: (@Sendable (String) -> Void)?) async throws -> [SubtitleCue] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?("Downloading Japanese speech model…")
            try await request.downloadAndInstall()
        }
        onStatus?("Transcribing audio…")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [SubtitleCue] in
            var cues: [SubtitleCue] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { continue }
                let startMs = Int((result.range.start.seconds * 1000).rounded())
                let endMs = Int((CMTimeRangeGetEnd(result.range).seconds * 1000).rounded())
                cues.append(SubtitleCue(index: cues.count + 1, startMs: startMs, endMs: max(endMs, startMs + 1), text: text))
            }
            return cues
        }
        let file = try AVAudioFile(forReading: url)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
