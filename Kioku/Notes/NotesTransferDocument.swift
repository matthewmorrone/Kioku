import SwiftUI
import UniformTypeIdentifiers

struct NotesTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var payload: NotesTransferPayload

    // Creates an exportable document from the current notes collection.
    init(notes: [Note]) {
        payload = NotesTransferPayload(notes: notes)
    }

    // Creates a transfer document from a previously exported JSON file URL.
    init(contentsOf fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        payload = try Self.decodePayload(from: data)
    }

    // Decodes a transfer document from the file importer read configuration.
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        payload = try Self.decodePayload(from: data)
    }

    // Serializes the payload into a JSON file for export.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return FileWrapper(regularFileWithContents: data)
    }

    // Supports both versioned exports and legacy raw note arrays during import.
    private static func decodePayload(from data: Data) throws -> NotesTransferPayload {
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(NotesTransferPayload.self, from: data) {
            return payload
        }

        let notes = try decoder.decode([Note].self, from: data)
        return NotesTransferPayload(notes: notes)
    }
}