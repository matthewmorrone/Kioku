// ZipExtractor.swift
// Minimal ZIP archive extractor that handles STORED (method 0) and DEFLATE (method 8) entries.
// Exists because iOS has no built-in zip API and the mlmodelc archives from HuggingFace
// are standard zip files. Uses system libz (always linked on Apple platforms) for raw inflate
// via @_silgen_name so no bridging header or external dependency is needed.

import Foundation

public enum ZipExtractor {

    // Allocation ceilings for untrusted archives. The downloaded model archives are
    // ~280–650 MB uncompressed; anything past these limits is a corrupt or hostile
    // file, not a bigger model. Bounding both per-entry and total prevents a crafted
    // header from forcing multi-gigabyte allocations out of a tiny download.
    public static let maxEntryUncompressedSize = 1 << 30        // 1 GiB per entry
    public static let maxTotalUncompressedSize = 2 << 30        // 2 GiB per archive

    // Extracts the ZIP archive at archiveURL into destinationURL. The archive is memory-mapped, so
    // its pages are file-backed and don't count against the app's memory limit the way a 580 MB
    // read into Data would; each entry is then written in bounded chunks (see writeEntry).
    public static func extract(archiveAt archiveURL: URL, to destinationURL: URL) throws {
        let zipData = try Data(contentsOf: archiveURL, options: .alwaysMapped)
        try extract(zipData: zipData, to: destinationURL)
    }

    // Extracts all entries from a ZIP archive into destinationURL.
    // Creates the destination directory and all subdirectories as needed.
    // Entry names are untrusted: each resolved path must stay inside
    // destinationURL or the archive is rejected (zip-slip traversal).
    public static func extract(zipData: Data, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var totalUncompressed = 0
        var offset = 0
        while offset + 30 <= zipData.count {
            let signature: UInt32 = zipData.read(at: offset)
            // Central directory or end-of-central-directory — nothing more to extract.
            if signature == 0x02014b50 || signature == 0x06054b50 {
                break
            }
            guard signature == 0x04034b50 else {
                throw ZipError.invalidSignature(at: offset)
            }

            let flags: UInt16 = zipData.read(at: offset + 6)
            let compressionMethod: UInt16 = zipData.read(at: offset + 8)
            let compressedSize: UInt32 = zipData.read(at: offset + 18)
            let uncompressedSize: UInt32 = zipData.read(at: offset + 22)
            let fileNameLength: UInt16 = zipData.read(at: offset + 26)
            let extraFieldLength: UInt16 = zipData.read(at: offset + 28)

            // Bit 3 of flags means sizes/CRC follow the data in a descriptor.
            // We rely on the local header sizes, so skip data-descriptor entries.
            if (flags & 0x0008) != 0 {
                break
            }

            let fileNameStart = offset + 30
            let dataStart = fileNameStart + Int(fileNameLength) + Int(extraFieldLength)
            let dataEnd = dataStart + Int(compressedSize)

            guard dataEnd <= zipData.count else {
                throw ZipError.truncated
            }

            let fileNameData = zipData[fileNameStart ..< fileNameStart + Int(fileNameLength)]
            let fileName = String(data: fileNameData, encoding: .utf8) ?? ""

            if !fileName.isEmpty {
                // Zip-slip defense on the entry name itself: no absolute paths, backslashes or ".."
                // segments. A lexical check, because comparing standardized URLs misfires on macOS,
                // where standardizing strips "/private" from paths that exist but not from ones that
                // don't yet.
                let segments = fileName.split(separator: "/", omittingEmptySubsequences: false)
                guard fileName.hasPrefix("/") == false,
                      fileName.contains("\\") == false,
                      segments.contains("..") == false else {
                    throw ZipError.unsafeEntryPath(fileName)
                }
                let dest = destinationURL.appendingPathComponent(fileName)

                totalUncompressed += Int(uncompressedSize)
                guard Int(uncompressedSize) <= maxEntryUncompressedSize,
                      totalUncompressed <= maxTotalUncompressedSize else {
                    throw ZipError.entryTooLarge(fileName)
                }

                if fileName.hasSuffix("/") {
                    // Directory entry.
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try writeEntry(
                        zipData[dataStart ..< dataEnd],
                        method: compressionMethod,
                        expectedSize: Int(uncompressedSize),
                        to: dest
                    )
                }
            }

            offset = dataEnd
        }
    }

    // Writes one entry's bytes to dest, STORED entries copied and DEFLATE entries inflated, in
    // chunks of at most chunkSize so peak memory stays a few MB no matter how large the entry is
    // (the model weights are a single ~600 MB entry). Reads the payload in place: no copy of the
    // compressed bytes is made.
    private static func writeEntry(_ payload: Data, method: UInt16, expectedSize: Int, to dest: URL) throws {
        guard method == 0 || method == 8 else { throw ZipError.unsupportedMethod(method) }
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw ZipError.cannotCreateFile(dest.lastPathComponent)
        }
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        let written: Int = try payload.withUnsafeBytes { input in
            method == 0
                ? try copyStored(input, to: handle)
                : try inflateRaw(input, to: handle)
        }
        guard written == expectedSize else { throw ZipError.sizeMismatch(dest.lastPathComponent) }
    }

    private static let chunkSize = 4 << 20

    // Copies a STORED entry straight from the (mapped) archive to the file, chunk by chunk.
    private static func copyStored(_ input: UnsafeRawBufferPointer, to handle: FileHandle) throws -> Int {
        var start = 0
        while start < input.count {
            let end = min(start + chunkSize, input.count)
            try handle.write(contentsOf: Data(UnsafeRawBufferPointer(rebasing: input[start ..< end])))
            start = end
        }
        return input.count
    }

    // Inflates a raw-DEFLATE entry into the file one output chunk at a time, returning the number
    // of bytes produced so the caller can check it against the local header.
    private static func inflateRaw(_ input: UnsafeRawBufferPointer, to handle: FileHandle) throws -> Int {
        guard let inBase = input.baseAddress, input.isEmpty == false else { return 0 }
        guard input.count <= Int(UInt32.max) else { throw ZipError.truncated }
        var stream = ZStream()
        // inflateInit2_ signature: (stream, windowBits, version_string, sizeof(z_stream))
        // The version string is checked for major-version compatibility only.
        let initStatus: Int32 = "1.2.11".withCString { ver in
            _inflateInit2(&stream, RAW_DEFLATE, ver, Int32(MemoryLayout<ZStream>.size))
        }
        guard initStatus == Z_OK else { throw ZipError.zlibInitFailed(initStatus) }
        defer { _ = _inflateEnd(&stream) }

        stream.nextIn = inBase.assumingMemoryBound(to: UInt8.self)
        stream.availIn = UInt32(input.count)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var status = Z_OK
        // Each pass fills at most one buffer; zlib reports Z_STREAM_END after the last byte.
        while status == Z_OK {
            let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                stream.nextOut = out.baseAddress
                stream.availOut = UInt32(out.count)
                status = _inflate(&stream, Z_NO_FLUSH)
                return out.count - Int(stream.availOut)
            }
            if produced > 0 {
                try handle.write(contentsOf: Data(buffer[0 ..< produced]))
            }
            if status == Z_OK, produced == 0, stream.availIn == 0 { break }
        }
        guard status == Z_STREAM_END else { throw ZipError.inflateFailed(status) }
        return Int(stream.totalOut)
    }
}

// MARK: – Raw inflate via system libz

// libz is always linked on Apple platforms. Declare only the symbols we need so no
// bridging header is required. @_silgen_name binds the Swift declaration to the C symbol.

private struct ZStream {
    // z_stream layout on 64-bit Apple (LP64). Verified against zlib.h field offsets:
    //   pointers = 8 bytes, uInt = 4 bytes (+ 4 padding before uLong), uLong = 8 bytes.
    var nextIn: UnsafePointer<UInt8>?           // offset   0, 8 bytes
    var availIn: UInt32 = 0                      // offset   8, 4 bytes
    private var _pad1: UInt32 = 0               // offset  12, 4 bytes (alignment padding)
    var totalIn: UInt = 0                        // offset  16, 8 bytes

    var nextOut: UnsafeMutablePointer<UInt8>?   // offset  24, 8 bytes
    var availOut: UInt32 = 0                     // offset  32, 4 bytes
    private var _pad2: UInt32 = 0              // offset  36, 4 bytes (alignment padding)
    var totalOut: UInt = 0                       // offset  40, 8 bytes

    private var msg: OpaquePointer? = nil        // offset  48, 8 bytes
    private var state: OpaquePointer? = nil      // offset  56, 8 bytes
    private var zalloc: OpaquePointer? = nil     // offset  64, 8 bytes (NULL = use default)
    private var zfree: OpaquePointer? = nil      // offset  72, 8 bytes (NULL = use default)
    private var opaque: OpaquePointer? = nil     // offset  80, 8 bytes

    var dataType: Int32 = 0                      // offset  88, 4 bytes
    private var _pad3: UInt32 = 0              // offset  92, 4 bytes (alignment padding)
    var adler: UInt = 0                          // offset  96, 8 bytes
    var reserved: UInt = 0                       // offset 104, 8 bytes
    // struct size: 112 bytes
}

// zlib return codes we care about.
private let Z_OK: Int32 = 0
private let Z_STREAM_END: Int32 = 1
private let Z_NO_FLUSH: Int32 = 0
// windowBits = -MAX_WBITS = -15 → raw DEFLATE without zlib/gzip header.
private let RAW_DEFLATE: Int32 = -15

// Binds zlib's inflateInit2_ directly so raw-DEFLATE streams can be decoded without a Swift wrapper.
@_silgen_name("inflateInit2_")
private func _inflateInit2(
    _ stream: UnsafeMutablePointer<ZStream>,
    _ windowBits: Int32,
    _ version: UnsafePointer<CChar>,
    _ streamSize: Int32
) -> Int32

// Binds zlib's inflate so decompression can be driven one buffer at a time from Swift.
@_silgen_name("inflate")
private func _inflate(_ stream: UnsafeMutablePointer<ZStream>, _ flush: Int32) -> Int32

// Binds zlib's inflateEnd so the stream state can be released after decompression completes.
@_silgen_name("inflateEnd")
private func _inflateEnd(_ stream: UnsafeMutablePointer<ZStream>) -> Int32

// MARK: – Helpers

private enum ZipError: LocalizedError {
    case invalidSignature(at: Int)
    case truncated
    case unsupportedMethod(UInt16)
    case zlibInitFailed(Int32)
    case inflateFailed(Int32)
    case unsafeEntryPath(String)
    case entryTooLarge(String)
    case cannotCreateFile(String)
    case sizeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidSignature(let o): return "Invalid ZIP signature at offset \(o)"
        case .truncated: return "ZIP data is truncated"
        case .unsupportedMethod(let m): return "Unsupported ZIP compression method \(m)"
        case .zlibInitFailed(let s): return "zlib inflateInit2 failed (status \(s))"
        case .inflateFailed(let s): return "zlib inflate failed (status \(s))"
        case .unsafeEntryPath(let name): return "ZIP entry path escapes the destination: \(name)"
        case .entryTooLarge(let name): return "ZIP entry exceeds the allowed size: \(name)"
        case .cannotCreateFile(let name): return "Could not create extracted file \(name)"
        case .sizeMismatch(let name): return "Extracted size of \(name) does not match the archive header"
        }
    }
}

private extension Data {
    // Reads a little-endian value from an offset without requiring alignment.
    func read<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
