import Foundation

// Reads and writes the folder list as `_folders.json` next to the per-note files. Kept apart from
// the note files so a corrupt folder list can never take a note down with it, and so a missing file
// (every install before folders existed) simply means "no folders".
enum NoteFolderFile {
    static let fileName = "_folders.json"

    // Loads the persisted folders. An absent file is the normal first-run case and stays quiet; an
    // unreadable one is logged and treated as empty so notes still open (they fall back to the top level).
    static func load(directory: URL, fileManager: FileManager) -> [NoteFolder] {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([NoteFolder].self, from: try Data(contentsOf: url))
        } catch {
            AppLog.error(.storage, "[NotesStore] folder list unreadable, treating as empty: \(error)")
            return []
        }
    }

    // Writes the folder list through the shared note file writer so tests can inject failures.
    static func save(_ folders: [NoteFolder], directory: URL, fileWriter: any NotesFileWriting) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try fileWriter.write(try encoder.encode(folders), to: url)
    }
}
