import SwiftWhisper

// Bridges WhisperDelegate callbacks into closures for use from SubtitleImportSheet.
// Must be a class because WhisperDelegate requires AnyObject.
final class WhisperTranscriptionDelegate: WhisperDelegate {
    // Called with a value 0–1 as inference progresses.
    var onProgress: ((Double) -> Void)?

    // Called with each batch of new segments as they are emitted during inference.
    var onNewSegments: (([Segment]) -> Void)?

    // Forwards inference progress to the onProgress closure.
    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        print("[Whisper] transcription progress: \(Int(progress * 100))%")
        onProgress?(progress)
    }

    // Forwards newly decoded segments to the onNewSegments closure for incremental display.
    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {
        let texts = segments.map(\.text).joined()
        print("[Whisper] new segment at \(index): \(texts)")
        onNewSegments?(segments)
    }

    // Logs transcription completion; callers obtain final segments via the async API, not this callback.
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {
        print("[Whisper] transcription complete — \(segments.count) segments")
    }

    // Logs inference errors; callers surface the error through the async API throw path.
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {
        print("[Whisper] transcription error: \(error)")
    }
}
