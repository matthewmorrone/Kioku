import Compression
import CryptoKit
import XCTest
@testable import Kioku

// Covers DictionaryArchiveExtractor, the step that turns the downloaded dictionary.sqlite.xz back
// into the database and yields the digest checked against DictionaryDownloadManager's pin.
final class DictionaryArchiveExtractorTests: XCTestCase {
    private var workDirectory: URL!

    // Gives each test its own scratch directory so archives and outputs never collide.
    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-archive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    // Removes the scratch directory.
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workDirectory)
    }

    // A multi-megabyte payload (larger than one 1 MB read) round-trips byte for byte, and the
    // returned digest is the SHA-256 of the uncompressed bytes.
    func testExtractRoundTripsAndReturnsDigestOfUncompressedBytes() throws {
        var payload = Data()
        for index in 0 ..< 400_000 {
            payload.append(contentsOf: "row \(index) 語彙 ".utf8)
        }
        let archiveURL = workDirectory.appendingPathComponent("dictionary.sqlite.xz")
        try lzmaCompress(payload).write(to: archiveURL)
        let outputURL = workDirectory.appendingPathComponent("dictionary.sqlite")

        let digest = try DictionaryArchiveExtractor.extract(archiveAt: archiveURL, to: outputURL)

        XCTAssertEqual(try Data(contentsOf: outputURL), payload)
        XCTAssertEqual(digest, SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    // A truncated archive must throw rather than yield a short database with a plausible digest.
    func testTruncatedArchiveThrows() throws {
        let compressed = try lzmaCompress(Data(repeating: 0x41, count: 3_000_000))
        let archiveURL = workDirectory.appendingPathComponent("truncated.xz")
        try compressed.prefix(compressed.count / 2).write(to: archiveURL)

        XCTAssertThrowsError(
            try DictionaryArchiveExtractor.extract(
                archiveAt: archiveURL,
                to: workDirectory.appendingPathComponent("out.sqlite")
            )
        )
    }

    // Produces an xz stream with the same Compression-framework codec the extractor decodes.
    private func lzmaCompress(_ data: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .lzma) { chunk in
            if let chunk { output.append(chunk) }
        }
        try filter.write(data)
        try filter.finalize()
        return output
    }
}
