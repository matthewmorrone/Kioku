import Compression
import CryptoKit
import Foundation

// Unpacks the downloaded dictionary.sqlite.xz. The release ships the database xz-compressed
// (~100 MB instead of ~384 MB); Apple's Compression framework decodes xz natively as `.lzma`.
// Decoding streams file-to-file in 1 MB reads and hashes the output as it is written, so neither
// the archive nor the database is ever held in memory and the checksum pin still covers the
// uncompressed database, exactly as it did when the raw file was downloaded.
nonisolated enum DictionaryArchiveExtractor {
    // Decompresses the xz archive at `archiveURL` into a new file at `destinationURL` and returns
    // the SHA-256 (lowercase hex) of the decompressed bytes. Throws on a corrupt or truncated
    // archive; the caller deletes the partial output.
    static func extract(archiveAt archiveURL: URL, to destinationURL: URL) throws -> String {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destinationURL.path])
        }
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var hasher = SHA256()
        let filter = try OutputFilter(.decompress, using: .lzma) { chunk in
            guard let chunk else { return }
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
        }
        var block = try input.read(upToCount: 1 << 20) ?? Data()
        while block.isEmpty == false {
            try filter.write(block)
            block = try input.read(upToCount: 1 << 20) ?? Data()
        }
        try filter.finalize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
