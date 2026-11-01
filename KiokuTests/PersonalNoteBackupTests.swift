import XCTest
@testable import Kioku

// A word's personal note travels with the saved word, so a backup carries it and restoring brings it back.
final class PersonalNoteBackupTests: XCTestCase {
    func testPersonalNoteSurvivesBackupRoundTrip() throws {
        let word = SavedWord(canonicalEntryID: 77, surface: "猫", personalNote: "neko — think 'nay-ko'")
        let payload = AppBackupPayload(
            notes: [], words: [word], wordLists: [], history: [], reviewStats: [], markedWrong: [],
            lifetimeCorrect: 0, lifetimeAgain: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(AppBackupPayload.self, from: encoder.encode(payload))
        XCTAssertEqual(restored.words.first?.canonicalEntryID, 77)
        XCTAssertEqual(restored.words.first?.personalNote, "neko — think 'nay-ko'")
    }
}
