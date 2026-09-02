import Foundation
import XCTest
@testable import Kioku

// Verifies the per-segment language splitting that lets listen-along switch voices inside a
// gist or definition: Japanese quoted in English text gets its own Japanese run (this is the
// "Japanese in the middle of English is skipped by TTS" fix), and vice versa, with neutral
// punctuation/spaces staying attached rather than becoming empty utterances.
final class SongListenLanguageRunsTests: XCTestCase {

    // Pure English stays one English run.
    func testPureEnglishIsOneRun() {
        let runs = SongListenLanguageRuns.split("Called your name.", defaultLanguage: .english)
        XCTAssertEqual(runs, [SongListenSegmentRun(text: "Called your name.", language: .english)])
    }

    // Pure Japanese stays one Japanese run.
    func testPureJapaneseIsOneRun() {
        let runs = SongListenLanguageRuns.split("君の名前を呼んだ", defaultLanguage: .japanese)
        XCTAssertEqual(runs, [SongListenSegmentRun(text: "君の名前を呼んだ", language: .japanese)])
    }

    // Japanese quoted inside an English definition is split out for the Japanese voice.
    func testJapaneseInsideEnglishGetsItsOwnRun() {
        let runs = SongListenLanguageRuns.split("\"I love you\", contracted 愛している (aishiteiru)", defaultLanguage: .english)
        XCTAssertEqual(runs.map(\.language), [.english, .japanese, .english])
        XCTAssertEqual(runs[1].text, "愛している")
    }

    // English inside a sung Japanese line is split out for the English voice.
    func testEnglishInsideJapaneseGetsItsOwnRun() {
        let runs = SongListenLanguageRuns.split("I said 愛してる to her", defaultLanguage: .japanese)
        XCTAssertEqual(runs.map(\.language), [.english, .japanese, .english])
        XCTAssertEqual(runs.map(\.text), ["I said", "愛してる", "to her"])
    }

    // Japanese punctuation stays with the Japanese run; a trailing ASCII period stays with
    // whatever run precedes it instead of forming its own.
    func testPunctuationStaysAttached() {
        let runs = SongListenLanguageRuns.split("黄昏 = 誰そ彼。", defaultLanguage: .english)
        XCTAssertEqual(runs.map(\.language), [.japanese])
        XCTAssertEqual(runs[0].text, "黄昏 = 誰そ彼。")
    }

    // Text with no letters at all is one run in the caller's default language.
    func testNoLettersUsesDefaultLanguage() {
        let runs = SongListenLanguageRuns.split("...", defaultLanguage: .japanese)
        XCTAssertEqual(runs, [SongListenSegmentRun(text: "...", language: .japanese)])
    }
}
