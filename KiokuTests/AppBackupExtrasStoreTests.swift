import XCTest
@testable import Kioku

@MainActor
final class AppBackupExtrasStoreTests: XCTestCase {
    // Device-local and secret keys must never be carried or overwritten by a backup.
    func testSettingAllowListExcludesDeviceLocalKeys() {
        XCTAssertTrue(AppBackupExtrasStore.isBackedUpSetting("kioku.settings.textSize"))
        XCTAssertFalse(AppBackupExtrasStore.isBackedUpSetting("kioku.lastActiveNoteID"))
        XCTAssertFalse(AppBackupExtrasStore.isBackedUpSetting("kioku.llm.openaiKey"))
        XCTAssertFalse(AppBackupExtrasStore.isBackedUpSetting("kioku.sing.history"))
        XCTAssertTrue(AppBackupExtrasStore.isBackedUpSetting("learn.flashcards.jlptLevels"))
        XCTAssertFalse(AppBackupExtrasStore.isBackedUpSetting("learn.pageIndex"))
        XCTAssertFalse(AppBackupExtrasStore.isBackedUpSetting("wordOfTheDay.enabled"))
    }

    // A zip written by the system archiver reads back with the same files, wrapper folder stripped.
    func testZipRoundTripPreservesFiles() throws {
        let json = Data("{\"a\":1}".utf8)
        let zipURL = try AppBackupArchive.build(json: json, audio: [], stemsDirectory: nil, stemFiles: [])
        XCTAssertTrue(AppBackupZip.isZip(at: zipURL))
        let opened = try AppBackupArchive.open(zipURL: zipURL)
        XCTAssertEqual(opened.json, json)
        try? FileManager.default.removeItem(at: opened.directory)
    }

    // Typed preference values survive the JSON round trip.
    func testSettingValueKeepsItsType() throws {
        let values: [String: AppBackupSettingValue] = ["b": .bool(true), "i": .int(3), "d": .double(1.5), "s": .string("x"), "l": .intList([1, 2]), "n": .stringList(["a"])]
        let decoded = try JSONDecoder().decode([String: AppBackupSettingValue].self, from: JSONEncoder().encode(values))
        XCTAssertEqual(decoded, values)
    }
}
