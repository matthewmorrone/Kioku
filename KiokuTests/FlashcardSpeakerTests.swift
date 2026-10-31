import AVFoundation
import XCTest
@testable import Kioku

// Pins what a flashcard speaks and when it speaks by itself.
final class FlashcardSpeakerTests: XCTestCase {
    func testSpeechTextPrefersKana() {
        XCTAssertEqual(FlashcardSpeaker.speechText(kanji: "生", kana: "いきる", surface: "生"), "いきる")
        XCTAssertEqual(FlashcardSpeaker.speechText(kanji: "生", kana: " ", surface: "生"), "生")
        XCTAssertEqual(FlashcardSpeaker.speechText(kanji: nil, kana: nil, surface: "ねこ"), "ねこ")
    }

    func testUtteranceUsesJapaneseVoice() {
        let utterance = FlashcardSpeaker.makeUtterance(for: "こんにちは")
        XCTAssertEqual(utterance.voice?.language, "ja-JP")
        XCTAssertEqual(utterance.speechString, "こんにちは")
    }

    func testAutoSpeakFollowsWhichSideShowsJapanese() {
        // Japanese on the front: speak when the card arrives, not again on the flip.
        XCTAssertTrue(FlashcardSpeaker.shouldAutoSpeak(isTop: true, hasContent: true, showBack: false, frontHasJapanese: true, backHasJapanese: false))
        XCTAssertFalse(FlashcardSpeaker.shouldAutoSpeak(isTop: true, hasContent: true, showBack: true, frontHasJapanese: true, backHasJapanese: false))
        // English first: stay silent until the flip reveals the Japanese.
        XCTAssertFalse(FlashcardSpeaker.shouldAutoSpeak(isTop: true, hasContent: true, showBack: false, frontHasJapanese: false, backHasJapanese: true))
        XCTAssertTrue(FlashcardSpeaker.shouldAutoSpeak(isTop: true, hasContent: true, showBack: true, frontHasJapanese: false, backHasJapanese: true))
        // Cards under the top one and cards still loading never speak.
        XCTAssertFalse(FlashcardSpeaker.shouldAutoSpeak(isTop: false, hasContent: true, showBack: false, frontHasJapanese: true, backHasJapanese: false))
        XCTAssertFalse(FlashcardSpeaker.shouldAutoSpeak(isTop: true, hasContent: false, showBack: false, frontHasJapanese: true, backHasJapanese: false))
    }
}
