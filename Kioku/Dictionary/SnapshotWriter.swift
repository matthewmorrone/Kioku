import Foundation

// Appends little-endian integers and length-prefixed UTF-8 strings to a byte buffer, for
// DictionaryTrie+Snapshot.
nonisolated struct SnapshotWriter {
    private(set) var data = Data()

    // Appends one integer's bytes, little-endian.
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // Appends a string as its UTF-8 byte count and bytes.
    mutating func append(_ string: String) {
        let bytes = Array(string.utf8)
        append(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
}
