import XCTest
@testable import Kioku

// Covers how the user's optional per-song note is folded into the breakdown request.
final class SongBreakdownPromptTests: XCTestCase {
    // A blank note must leave the user turn as the bare lyrics so existing requests are unchanged.
    func testBlankNoteSendsLyricsOnly() {
        XCTAssertEqual(SongBreakdownPrompt.userTurn(lyrics: "歌詞", userNote: "  \n"), "歌詞")
    }

    // A note is appended after the lyrics under its own header so the model sees it as guidance.
    func testNoteIsAppendedAfterLyrics() {
        let turn = SongBreakdownPrompt.userTurn(lyrics: "歌詞", userNote: "ignore parentheses")
        XCTAssertTrue(turn.hasPrefix("歌詞\n\n## Additional instructions for this song"))
        XCTAssertTrue(turn.hasSuffix("ignore parentheses"))
    }

    // The combined OpenAI prompt carries the note in place of the lyrics marker.
    func testInstantiatedIncludesNote() {
        let prompt = SongBreakdownPrompt.instantiated(withLyrics: "歌詞", userNote: "ignore parentheses")
        XCTAssertFalse(prompt.contains(SongBreakdownPrompt.lyricsMarker))
        XCTAssertTrue(prompt.contains("ignore parentheses"))
    }
}
