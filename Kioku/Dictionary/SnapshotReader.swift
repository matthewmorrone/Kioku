import Foundation

// Reads what SnapshotWriter wrote, in order, from a byte buffer. Every read returns nil instead of
// reading past the end, so a truncated file fails cleanly.
nonisolated struct SnapshotReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset = 0

    // A reader at the start of `buffer`.
    init(buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    // Whether every byte has been read.
    var isAtEnd: Bool { offset == buffer.count }

    // The next little-endian integer of type T, or nil past the end.
    private mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= buffer.count else { return nil }
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += size
        return T(littleEndian: value)
    }

    // The next byte.
    mutating func uint8() -> UInt8? { integer(UInt8.self) }

    // The next 32-bit integer.
    mutating func uint32() -> UInt32? { integer(UInt32.self) }

    // The next 64-bit integer.
    mutating func uint64() -> UInt64? { integer(UInt64.self) }

    // The next length-prefixed UTF-8 string.
    mutating func string() -> String? {
        guard let count = uint32(), offset + Int(count) <= buffer.count else { return nil }
        let string = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + Int(count)]), as: UTF8.self)
        offset += Int(count)
        return string
    }
}
