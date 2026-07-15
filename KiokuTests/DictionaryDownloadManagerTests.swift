import XCTest
@testable import Kioku

final class DictionaryDownloadManagerTests: XCTestCase {
    func testInstalledDatabaseURLPointsUnderApplicationSupportDictionary() {
        let url = DictionaryDownloadManager.installedDatabaseURL
        XCTAssertEqual(url.lastPathComponent, "dictionary.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Dictionary")
    }

    func testSHA256OfFileMatchesKnownDigest() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-sha256-test-\(UUID().uuidString).txt")
        try "hello world\n".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let digest = try DictionaryDownloadManager.sha256(ofFileAt: tempURL)
        XCTAssertEqual(digest, "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    }

    // Exercises DictionaryStore's no-arg init against whatever the real Application Support
    // state is: if a dictionary happens to already be installed (e.g. a prior manual test run),
    // opening it should succeed; if not, it must throw .databaseNotFound rather than crash or
    // hang. Both branches are asserted so the test is meaningful either way, without touching or
    // deleting real on-disk state.
    func testDictionaryStoreThrowsDatabaseNotFoundWhenNotInstalled() {
        do {
            _ = try DictionaryStore()
            XCTAssertTrue(DictionaryDownloadManager.isInstalled, "DictionaryStore() succeeded but isInstalled is false")
        } catch DictionarySQLiteError.databaseNotFound(let name) {
            XCTAssertEqual(name, "dictionary.sqlite")
            XCTAssertFalse(DictionaryDownloadManager.isInstalled)
        } catch {
            XCTFail("expected .databaseNotFound, got \(error)")
        }
    }
}
