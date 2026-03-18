import SwiftWhisper

// Bridges WhisperDelegate callbacks into closures for use from SubtitleImportSheet.
// Must be a class because WhisperDelegate requires AnyObject.
final class WhisperTranscriptionDelegate: WhisperDelegate {
    // Called with a value 0–1 as inference progresses.
    var onProgress: ((Double) -> Void)?

    // Called with each batch of new segments as they are emitted during inference.
    var onNewSegments: (([Segment]) -> Void)?

    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        print("[Whisper] transcription progress: \(Int(progress * 100))%")
        onProgress?(progress)
    }

    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        let texts = segments.map(\.text).joined()
        print("[Whisper] new segment at \(index): \(texts)")
        onNewSegments?(segments)
    }

    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {
        print("[Whisper] transcription complete — \(segments.count) segments")
    }

    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        print("[Whisper] transcription error: \(error)")
    }
}
