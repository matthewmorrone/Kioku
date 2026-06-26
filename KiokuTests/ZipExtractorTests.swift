import XCTest
import SwiftWhisperAlign

// Pins the untrusted-archive guarantees: entry paths cannot escape the destination
// directory (zip-slip) and declared sizes cannot force unbounded allocation.
@MainActor
final class ZipExtractorTests: XCTestCase {
    private var destination: URL!

    override func setUpWithError() throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-extractor-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: destination)
    }

    // A well-formed STORED entry extracts to the expected relative path.
    func testExtractsStoredEntryInsideDestination() throws {
        let payload = Data("hello".utf8)
        let archive = makeStoredEntry(name: "model/weights.bin", payload: payload)

        try ZipExtractor.extract(zipData: archive, to: destination)

        let extracted = destination.appendingPathComponent("model/weights.bin")
        XCTAssertEqual(try Data(contentsOf: extracted), payload)
    }

    // "../" entry names must be rejected before any byte is written outside the destination.
    func testRejectsPathTraversalEntry() throws {
        let escapeTarget = destination.deletingLastPathComponent()
            .appendingPathComponent("zip-slip-escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: escapeTarget) }

        let archive = makeStoredEntry(
            name: "../\(escapeTarget.lastPathComponent)",
            payload: Data("escaped".utf8)
        )

        XCTAssertThrowsError(try ZipExtractor.extract(zipData: archive, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget.path))
    }

    // Absolute entry names are equally hostile and must be rejected.
    func testRejectsAbsoluteEntryPath() throws {
        let archive = makeStoredEntry(name: "/tmp/zip-slip-absolute.txt", payload: Data("x".utf8))
        XCTAssertThrowsError(try ZipExtractor.extract(zipData: archive, to: destination))
    }

    // A header claiming a multi-gigabyte uncompressed size must be rejected up front,
    // not allocated.
    func testRejectsOversizedDeclaredEntry() throws {
        let archive = makeStoredEntry(
            name: "huge.bin",
            payload: Data("tiny".utf8),
            declaredUncompressedSize: UInt32(ZipExtractor.maxEntryUncompressedSize + 1)
        )
        XCTAssertThrowsError(try ZipExtractor.extract(zipData: archive, to: destination))
    }

    // Builds one ZIP local-file-header record with a STORED (method 0) payload.
    private func makeStoredEntry(
        name: String,
        payload: Data,
        declaredUncompressedSize: UInt32? = nil
    ) -> Data {
        let nameBytes = Data(name.utf8)
        var data = Data()
        data.appendLE(UInt32(0x04034b50))                 // local file header signature
        data.appendLE(UInt16(20))                          // version needed
        data.appendLE(UInt16(0))                           // flags
        data.appendLE(UInt16(0))                           // method 0 = STORED
        data.appendLE(UInt16(0))                           // mod time
        data.appendLE(UInt16(0))                           // mod date
        data.appendLE(UInt32(0))                           // crc-32 (not validated)
        data.appendLE(UInt32(payload.count))               // compressed size
        data.appendLE(declaredUncompressedSize ?? UInt32(payload.count)) // uncompressed size
        data.appendLE(UInt16(nameBytes.count))             // file name length
        data.appendLE(UInt16(0))                           // extra field length
        data.append(nameBytes)
        data.append(payload)
        return data
    }
}

private extension Data {
    // Appends a fixed-width integer in ZIP's little-endian wire order.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
