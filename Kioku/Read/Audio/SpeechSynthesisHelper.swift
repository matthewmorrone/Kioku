import AVFoundation

// Shared on-device speech for every one-off "tap to hear this word" affordance in the app (segment
// lookup sheet, conjugation sheet, word detail, word list rows). Centralized for two reasons:
//
// 1. One long-lived synthesizer. Creating a fresh AVSpeechSynthesizer and calling speak() on it
//    immediately is a well-known trigger for it silently dropping or truncating that first
//    utterance; a per-tap instance would hit that on every tap. A single instance pays it once.
// 2. Audible on silent. Activating `.playback` here (as AudioPlaybackController does for song audio)
//    makes tap-to-hear audible regardless of the mute switch, matching what users expect from a
//    "speak this word" button; without it playback runs under whatever category is active, typically
//    one that respects the mute switch.
//
// Voice selection: deliberately NOT passing a specific voice identifier. Passing nil (the default)
// lets AVSpeechUtterance resolve the voice the same way `AVSpeechSynthesisVoice(language:)` does —
// the OS default voice for that language, which is exactly what the user configured in Settings >
// Accessibility > Spoken Content > Voices. There is nowhere in this app that lets the user pick a
// *different* voice, so honoring that system default is the correct behavior everywhere speech is
// spoken.
@MainActor
final class SpeechSynthesisHelper {
    static let shared = SpeechSynthesisHelper()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    // Speaks `text` using the OS default voice for `languageCode` (e.g. "ja-JP", "en-US").
    // Stops any in-flight utterance first so rapid taps don't queue up and talk over each other.
    func speak(_ text: String, languageCode: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        activateSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        synthesizer.speak(utterance)
    }

    // Activates a playback-category audio session so the utterance is audible even with the
    // hardware mute switch on, mirroring AudioPlaybackController's own session setup for song
    // playback. `.mixWithOthers` avoids interrupting song audio that may already be playing.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            AppLog.error(.audioPlayback, "[SpeechSynthesisHelper] audio session activation failed: \(error.localizedDescription)")
        }
    }
}
