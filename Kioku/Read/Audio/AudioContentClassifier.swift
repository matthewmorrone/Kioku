import Foundation
import AVFoundation
import SoundAnalysis

// Tells spoken audio from sung audio before transcription, so singing can be steered toward
// published lyrics (transcription is unreliable on songs) while speech transcribes straight away.
// Runs Apple's built-in on-device sound classifier over 3-second windows and compares how many
// windows it labels speech against how many it labels singing or music. On 12 song mixes vs 30
// FLEURS read-speech clips (2026-09-23) that rule separated every file: songs 0% speech windows,
// speech clips 0% sung/music windows on all but one (33%, still a two-to-one speech majority).
enum AudioContentClassifier {
    nonisolated static let windowSeconds = 3.0

    // Classifies the file at `url`. Unclear when the classifier can't be run or neither side has
    // any windows (silence, noise); otherwise whichever side has more windows.
    static func classify(_ url: URL) async -> AudioContentKind {
        await Task.detached(priority: .userInitiated) {
            do {
                let analyzer = try SNAudioFileAnalyzer(url: url)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 48_000)
                request.overlapFactor = 0
                let tally = AudioContentWindowTally()
                try analyzer.add(request, withObserver: tally)
                analyzer.analyze()
                return tally.kind
            } catch {
                AppLog.error(.transcription, "audio content classification failed: \(error)")
                return .unclear
            }
        }.value
    }
}
