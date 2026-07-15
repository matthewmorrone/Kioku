import XCTest
@testable import Kioku

// Characterizes DownloadedModelsStore's path-in/byte-count-out logic (sizeBytes, removeContents)
// against disposable temp directories — never the real Application Support model tree, since
// that may hold genuine downloaded weights on a device that's used the app's alignment or
// bulk-import features. Each test gets its own UUID-named subdirectory under the system temp
// directory so cases never collide with each other or with a real download.
final class DownloadedModelsStoreTests: XCTestCase {

    private var testRoot: URL!

    override func setUp() {
        super.setUp()
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-downloaded-models-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testRoot)
        testRoot = nil
        super.tearDown()
    }

    // Writes `bytes` of dummy content to a file at `relativePath` under testRoot, creating
    // intermediate directories as needed.
    private func writeFile(_ relativePath: String, bytes: Int) {
        let url = testRoot.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: bytes))
    }

    // MARK: - sizeBytes

    func testSizeBytesOfNilRootIsZero() {
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: nil), 0)
    }

    func testSizeBytesOfNonexistentDirectoryIsZero() {
        let missing = testRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: missing), 0)
    }

    func testSizeBytesOfEmptyDirectoryIsZero() {
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: testRoot), 0)
    }

    func testSizeBytesSumsFlatFiles() {
        writeFile("a.bin", bytes: 100)
        writeFile("b.bin", bytes: 250)
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: testRoot), 350)
    }

    // Real models are nested directory bundles (HTDemucs' .mlmodelc holds model.mil + weights/ +
    // metadata), so the sum must recurse into subdirectories, not just the top level.
    func testSizeBytesSumsNestedSubdirectories() {
        writeFile("model.mil", bytes: 100)
        writeFile("weights/part1.bin", bytes: 200)
        writeFile("weights/nested/part2.bin", bytes: 300)
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: testRoot), 600)
    }

    // Mirrors the enumerator's .skipsHiddenFiles option — a stray .DS_Store shouldn't inflate
    // the size readout shown to the user.
    func testSizeBytesSkipsHiddenFiles() {
        writeFile("visible.bin", bytes: 100)
        writeFile(".DS_Store", bytes: 999)
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: testRoot), 100)
    }

    // MARK: - removeContents

    func testRemoveContentsOfNilRootIsSafeNoOp() {
        DownloadedModelsStore.removeContents(of: nil)
        // Reaching this line without a crash is the assertion; nothing else to check.
    }

    func testRemoveContentsClearsFlatFiles() {
        writeFile("a.bin", bytes: 100)
        writeFile("b.bin", bytes: 200)
        DownloadedModelsStore.removeContents(of: testRoot)
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: testRoot), 0)
    }

    // removeContents deletes top-level entries (files AND directories); a directory entry's
    // removeItem recurses, so nested content must be gone too.
    func testRemoveContentsClearsNestedSubdirectories() {
        writeFile("model.mil", bytes: 100)
        writeFile("weights/part1.bin", bytes: 200)
        DownloadedModelsStore.removeContents(of: testRoot)
        XCTAssertEqual(DownloadedModelsStore.sizeBytes(at: testRoot), 0)
    }

    // The root directory itself must survive — ModelStorage.directory(for:) would otherwise
    // recreate it on the next call anyway, but leaving it in place avoids that extra hop.
    func testRemoveContentsLeavesRootDirectoryInPlace() {
        writeFile("a.bin", bytes: 100)
        DownloadedModelsStore.removeContents(of: testRoot)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: testRoot.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }
}
