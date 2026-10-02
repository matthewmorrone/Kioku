import XCTest
@testable import Kioku

// Covers how the user's optional per-song note is folded into the breakdown request.
@MainActor
final class SongBreakdownPromptTests: XCTestCase {
    // A blank note leaves the user turn as just the lyrics section.
    func testBlankNoteSendsLyricsOnly() {
        XCTAssertEqual(SongBreakdownPrompt.userTurn(lyrics: "歌詞", userNote: "  \n"), "## Lyrics\n\n歌詞")
    }

    // A note comes before the lyrics under the header rule 12 names, so the model reads it first.
    func testNoteComesBeforeLyrics() {
        let turn = SongBreakdownPrompt.userTurn(lyrics: "歌詞", userNote: "ignore parentheses")
        XCTAssertEqual(turn, "## Instructions for this song\n\nignore parentheses\n\n## Lyrics\n\n歌詞")
        XCTAssertTrue(SongBreakdownPrompt.staticInstructions().contains("\"Instructions for this song\""))
    }

    // The combined OpenAI prompt carries the note in place of the lyrics marker.
    func testInstantiatedIncludesNote() {
        let prompt = SongBreakdownPrompt.instantiated(withLyrics: "歌詞", userNote: "ignore parentheses")
        XCTAssertFalse(prompt.contains(SongBreakdownPrompt.lyricsMarker))
        XCTAssertTrue(prompt.contains("ignore parentheses"))
    }
}
