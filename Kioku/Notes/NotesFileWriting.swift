import Foundation

// Abstracts irreversible note-file mutations so persistence failures can be
// tested and NotesStore can advance its disk snapshot only after success.
protocol NotesFileWriting: AnyObject {
    // Persists encoded note data or the ordering index at the requested URL.
    func write(_ data: Data, to url: URL) throws

    // Removes a note file that no longer belongs to the persisted collection.
    func removeItem(at url: URL) throws
}

// Performs production note-file writes using atomic Foundation operations.
final class NotesFileWriter: NotesFileWriting {
    // Writes one encoded note or index without exposing a partially written file.
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    // Removes one note file that is no longer part of the persisted collection.
    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
