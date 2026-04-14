// ZipExtractor.swift
// Minimal ZIP archive extractor that handles STORED (method 0) and DEFLATE (method 8) entries.
// Exists because iOS has no built-in zip API and the mlmodelc archives from HuggingFace
// are standard zip files. Uses system libz (always linked on Apple platforms) for raw inflate
// via @_silgen_name so no bridging header or external dependency is needed.

import Foundation

enum ZipExtractor {

    // Extracts all entries from a ZIP archive into destinationURL.
    // Creates the destination directory and all subdirectories as needed.
    static func extract(zipData: Data, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

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
                let dest = destinationURL.appendingPathComponent(fileName)
                if fileName.hasSuffix("/") {
                    // Directory entry.
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let payload = zipData[dataStart ..< dataEnd]
                    let fileData: Data
                    switch compressionMethod {
                    case 0:  // STORED — copy bytes directly.
                        fileData = Data(payload)
                    case 8:  // DEFLATE — raw inflate via libz.
                        fileData = try inflate(Data(payload), expectedSize: Int(uncompressedSize))
                    default:
                        throw ZipError.unsupportedMethod(compressionMethod)
                    }
                    try fileData.write(to: dest)
                }
            }

            offset = dataEnd
        }
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
private let Z_FINISH: Int32 = 4
// windowBits = -MAX_WBITS = -15 → raw DEFLATE without zlib/gzip header.
private let RAW_DEFLATE: Int32 = -15

@_silgen_name("inflateInit2_")
private func _inflateInit2(
    _ stream: UnsafeMutablePointer<ZStream>,
    _ windowBits: Int32,
    _ version: UnsafePointer<CChar>,
    _ streamSize: Int32
) -> Int32

@_silgen_name("inflate")
private func _inflate(_ stream: UnsafeMutablePointer<ZStream>, _ flush: Int32) -> Int32

@_silgen_name("inflateEnd")
private func _inflateEnd(_ stream: UnsafeMutablePointer<ZStream>) -> Int32

// Decompresses raw DEFLATE data. expectedSize comes from the ZIP local header.
private func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
    guard !compressed.isEmpty else { return Data() }

    var output = Data(count: max(expectedSize, 1))
    var stream = ZStream()

    // inflateInit2_ signature: (stream, windowBits, version_string, sizeof(z_stream))
    // The version string is checked for major-version compatibility only.
    let initStatus: Int32 = "1.2.11".withCString { ver in
        _inflateInit2(&stream, RAW_DEFLATE, ver, Int32(MemoryLayout<ZStream>.size))
    }
    guard initStatus == Z_OK else {
        throw ZipError.zlibInitFailed(initStatus)
    }
    defer { _ = _inflateEnd(&stream) }

    let outputCount = output.count
    let status: Int32 = compressed.withUnsafeBytes { inBuf in
        guard let inBase = inBuf.baseAddress else { return -99 as Int32 }
        return output.withUnsafeMutableBytes { outBuf in
            guard let outBase = outBuf.baseAddress else { return -99 as Int32 }
            stream.nextIn = inBase.assumingMemoryBound(to: UInt8.self)
            stream.availIn = UInt32(compressed.count)
            stream.nextOut = outBase.assumingMemoryBound(to: UInt8.self)
            stream.availOut = UInt32(outputCount)
            return _inflate(&stream, Z_FINISH)
        }
    }

    guard status == Z_STREAM_END else {
        throw ZipError.inflateFailed(status)
    }
    output.count = Int(stream.totalOut)
    return output
}

// MARK: – Helpers

private enum ZipError: LocalizedError {
    case invalidSignature(at: Int)
    case truncated
    case unsupportedMethod(UInt16)
    case zlibInitFailed(Int32)
    case inflateFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSignature(let o): return "Invalid ZIP signature at offset \(o)"
        case .truncated: return "ZIP data is truncated"
        case .unsupportedMethod(let m): return "Unsupported ZIP compression method \(m)"
        case .zlibInitFailed(let s): return "zlib inflateInit2 failed (status \(s))"
        case .inflateFailed(let s): return "zlib inflate failed (status \(s))"
        }
    }
}

private extension Data {
    // Reads a little-endian value from an offset without requiring alignment.
    func read<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
