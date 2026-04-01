import SwiftUI
import UniformTypeIdentifiers

// Reads and writes the current full-app backup JSON format.
struct AppBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var payload: AppBackupPayload

    // Creates an exportable app-backup document from one full payload snapshot.
    init(payload: AppBackupPayload) {
        self.payload = payload
    }

    // Creates an app-backup document from a previously exported backup file URL.
    init(contentsOf fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        payload = try Self.decodePayload(from: data)
    }

    // Decodes an app-backup document from the file importer read configuration.
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        payload = try Self.decodePayload(from: data)
    }

    // Serializes the payload into a JSON backup file for export.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return FileWrapper(regularFileWithContents: data)
    }

    // Decodes the current versioned app-backup payload format.
    private static func decodePayload(from data: Data) throws -> AppBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(AppBackupPayload.self, from: data)
        guard payload.version == AppBackupPayload.currentVersion else {
            throw NSError(
                domain: "Kioku.AppBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported app backup version \(payload.version). Expected version \(AppBackupPayload.currentVersion)."]
            )
        }
        return payload
    }
}
