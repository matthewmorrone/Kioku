import AVFoundation
import Foundation

// Speaks a flashcard's Japanese word with the system ja-JP voice. One shared instance so starting a
// new card cuts off the previous one instead of overlapping, and so audio ducking is released when
// speech ends. The speech text and the auto-play decision are pure statics so they can be tested.
@MainActor
final class FlashcardSpeaker: NSObject {
    static let shared = FlashcardSpeaker()
    // UserDefaults key for the "speak each card automatically" option.
    static let autoPlayKey = "learn.flashcards.autoSpeak"

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // What to read aloud for a card. The kana reading is preferred: the voice reads kana
    // unambiguously, where a kanji headword can be read the wrong way (生 alone has many readings).
    nonisolated static func speechText(kanji: String?, kana: String?, surface: String) -> String {
        for candidate in [kana, kanji, surface] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false {
                return trimmed
            }
        }
        return surface
    }

    // Whether a card should speak by itself right now: when the Japanese word comes into view on
    // the front, or — for an English-first card — when it is flipped to reveal the Japanese.
    nonisolated static func shouldAutoSpeak(
        isTop: Bool,
        hasContent: Bool,
        showBack: Bool,
        frontHasJapanese: Bool,
        backHasJapanese: Bool
    ) -> Bool {
        guard isTop, hasContent else { return false }
        return showBack ? (backHasJapanese && frontHasJapanese == false) : frontHasJapanese
    }

    // The utterance for `text`: ja-JP voice at a learner-friendly pace.
    nonisolated static func makeUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        return utterance
    }

    // Speaks `text`, replacing anything still being spoken. Audio plays through the speaker even
    // with the silent switch on and ducks other audio (a playing song) while it speaks.
    func speak(_ text: String) {
        guard text.isEmpty == false else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            AppLog.error(.audioPlayback, "[FlashcardSpeaker] audio session setup failed: \(error)")
        }
        synthesizer.speak(Self.makeUtterance(for: text))
    }

    // Stops speech, e.g. when the card leaves the screen.
    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    // Releases the audio session so ducked audio returns to full volume.
    private func releaseAudioSession() {
        guard synthesizer.isSpeaking == false else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.error(.audioPlayback, "[FlashcardSpeaker] audio session release failed: \(error)")
        }
    }
}

extension FlashcardSpeaker: AVSpeechSynthesizerDelegate {
    // Un-ducks other audio once an utterance ends.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseAudioSession() }
    }

    // Un-ducks other audio when an utterance is cancelled (a newer one replaces it, which keeps
    // isSpeaking true and so skips the release).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseAudioSession() }
    }
}
