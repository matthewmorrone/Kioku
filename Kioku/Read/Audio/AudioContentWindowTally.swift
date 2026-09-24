import Foundation
import SoundAnalysis

// Collects AudioContentClassifier's per-window top labels and turns them into a verdict. The
// sound classifier's own taxonomy decides the buckets: speech-like labels vs singing/music labels;
// everything else (silence, clicks, room noise between words) counts toward neither.
nonisolated final class AudioContentWindowTally: NSObject, SNResultsObserving, @unchecked Sendable {
    private var speechWindows = 0
    private var sungWindows = 0

    // Buckets one window by its top label.
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let top = (result as? SNClassificationResult)?.classifications.first?.identifier else { return }
        if top == "speech" || top.contains("conversation") || top == "narration_monologue" {
            speechWindows += 1
        } else if top.contains("sing") || top == "choir" || top.contains("music") || top == "rapping" || top == "humming" {
            sungWindows += 1
        }
    }

    // Logs a failed analysis; the verdict then falls back to whatever windows arrived.
    func request(_ request: SNRequest, didFailWithError error: Error) {
        AppLog.error(.transcription, "sound classification window failed: \(error)")
    }

    // The side with more windows; unclear on a tie (including no labelled windows at all).
    var kind: AudioContentKind {
        if speechWindows > sungWindows { return .speech }
        if sungWindows > speechWindows { return .singing }
        return .unclear
    }
}
