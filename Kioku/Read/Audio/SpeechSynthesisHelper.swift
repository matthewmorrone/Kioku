import AVFoundation

// Shared on-device speech for every one-off "tap to hear this word" affordance in the app
// (segment lookup sheet, conjugation sheet, word detail, word list rows). Two bugs this fixes
// by centralizing:
//
// 1. Inaudible/truncated taps: several call sites used to create a brand-new
//    AVSpeechSynthesizer and call speak() on it immediately, which is a well-known trigger for
//    AVSpeechSynthesizer silently dropping or truncating the very first utterance spoken on a
//    freshly-initialized instance — since a fresh instance was created on *every* tap, this
//    bug fired on every tap, not just a one-time cold start. A single long-lived synthesizer
//    only pays that cost once, for the app's very first utterance.
// 2. Nothing audible when the phone is muted/on silent: none of those call sites ever touched
//    AVAudioSession, so playback ran under whatever category (or none at all) happened to be
//    active — typically one that respects the hardware mute switch. Activating `.playback`
//    here (as AudioPlaybackController already does for song audio) makes tap-to-hear audible
//    regardless of the mute switch, matching what users expect from a "speak this word" button.
//
// Voice selection: deliberately NOT passing a specific voice identifier. Passing nil (the
// default) lets AVSpeechUtterance resolve the voice the same way `AVSpeechSynthesisVoice
// (language:)` does — the OS default voice for that language, which is exactly what the user
// configured in Settings > Accessibility > Spoken Content > Voices. There is nowhere in this
// app that lets the user pick a *different* voice, so honoring that system default is the
// correct behavior everywhere speech is spoken.
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
            print("[SpeechSynthesisHelper] audio session activation failed: \(error.localizedDescription)")
        }
    }
}
