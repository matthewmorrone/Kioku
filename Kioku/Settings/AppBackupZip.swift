import Compression
import Foundation

// Zip container for backups that carry audio and vocal stems. Writing leans on the system:
// NSFileCoordinator's .forUploading option zips a directory. iOS has no public zip reader, so
// reading is a small central-directory parser that handles stored and deflated entries
// (Compression's COMPRESSION_ZLIB decodes the raw deflate stream a zip entry holds).
nonisolated enum AppBackupZip {
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    // True when the file begins with the zip magic "PK", which is how import tells a zip backup
    // from a plain JSON one without trusting the file extension.
    static func isZip(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return head == Data([0x50, 0x4B])
    }

    // Zips the contents of `directory` into a new file at `destination`. The system archive wraps
    // everything in a folder named after the directory; extraction strips that wrapper.
    static func zip(directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                // The coordinator's zip is deleted when this block returns, so it is copied out here.
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    // Extracts every file entry of the zip into `directory`, dropping a single wrapper folder.
    // Rejects entries whose path could land outside `directory`.
    static func extract(zipURL: URL, to directory: URL) throws {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let entries = try centralDirectory(of: data)
        let wrapper = commonWrapper(of: entries.map(\.name))
        let root = directory.standardizedFileURL
        for entry in entries where entry.name.hasSuffix("/") == false && entry.name.hasPrefix("__MACOSX/") == false {
            let relative = String(entry.name.dropFirst(wrapper.count))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.isEmpty == false, components.allSatisfy({ $0.isEmpty == false && $0 != ".." && $0 != "." }) else {
                throw AppBackupValidationError.invalid("the zip contains an unsafe path.")
            }
            let target = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw AppBackupValidationError.invalid("the zip contains an unsafe path.")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileBytes(of: entry, in: data).write(to: target, options: .atomic)
        }
    }

    // One central-directory record: where an entry's bytes are and how they are stored.
    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    // The folder prefix shared by every entry ("staging/"), or "" when entries sit at the top level.
    private static func commonWrapper(of names: [String]) -> String {
        let files = names.filter { $0.hasSuffix("/") == false && $0.hasPrefix("__MACOSX/") == false }
        guard let first = files.first, let slash = first.firstIndex(of: "/") else { return "" }
        let prefix = String(first[...slash])
        return files.allSatisfy { $0.hasPrefix(prefix) } ? prefix : ""
    }

    // Parses the end-of-central-directory record and every central header after it.
    private static func centralDirectory(of data: Data) throws -> [Entry] {
        let corrupt = AppBackupValidationError.invalid("the zip file is damaged or unsupported.")
        guard data.count >= 22 else { throw corrupt }
        // The record sits at the end, followed only by an optional comment of at most 65535 bytes.
        var eocd = -1
        var offset = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while offset >= lowest && eocd < 0 {
            if try readUInt32(data, offset) == endOfCentralDirectorySignature { eocd = offset }
            offset -= 1
        }
        guard eocd >= 0 else { throw corrupt }

        let entryCount = Int(try readUInt16(data, eocd + 10))
        let directoryOffset = Int(try readUInt32(data, eocd + 16))
        guard entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw corrupt }

        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<entryCount {
            guard try readUInt32(data, cursor) == centralHeaderSignature else { throw corrupt }
            let method = try readUInt16(data, cursor + 10)
            let compressed = Int(try readUInt32(data, cursor + 20))
            let uncompressed = Int(try readUInt32(data, cursor + 24))
            let nameLength = Int(try readUInt16(data, cursor + 28))
            let extraLength = Int(try readUInt16(data, cursor + 30))
            let commentLength = Int(try readUInt16(data, cursor + 32))
            let localOffset = Int(try readUInt32(data, cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { throw corrupt }
            let nameBytes = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameBytes, encoding: .utf8) else { throw corrupt }
            entries.append(Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localOffset: localOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // The entry's uncompressed bytes, from its local header's data (stored or deflated).
    private static func fileBytes(of entry: Entry, in data: Data) throws -> Data {
        let corrupt = AppBackupValidationError.invalid("the zip file is damaged or unsupported.")
        guard try readUInt32(data, entry.localOffset) == localHeaderSignature else { throw corrupt }
        let nameLength = Int(try readUInt16(data, entry.localOffset + 26))
        let extraLength = Int(try readUInt16(data, entry.localOffset + 28))
        let start = entry.localOffset + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw corrupt }
        let stored = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return stored
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { out in
                stored.withUnsafeBytes { input in
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        input.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == entry.uncompressedSize else { throw corrupt }
            return output
        default:
            throw corrupt
        }
    }

    // Reads a little-endian UInt16, failing instead of trapping when the offset is out of range.
    private static func readUInt16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw AppBackupValidationError.invalid("the zip file is damaged or unsupported.") }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    // Reads a little-endian UInt32, failing instead of trapping when the offset is out of range.
    private static func readUInt32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw AppBackupValidationError.invalid("the zip file is damaged or unsupported.") }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
