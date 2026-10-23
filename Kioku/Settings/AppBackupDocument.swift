import SwiftUI
import UniformTypeIdentifiers

// Reads and writes the current full-app backup: one JSON file, or a zip when audio or stems come along.
nonisolated struct AppBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .zip] }

    var payload: AppBackupPayload
    // A finished zip to export as-is (a backup with audio or stems); nil for a plain JSON export.
    var archiveURL: URL?
    // The extracted folder of an imported zip backup, holding its audio/ and stems/ files.
    var assetsDirectory: URL?

    // Creates an exportable app-backup document from one full payload snapshot.
    init(payload: AppBackupPayload) {
        self.payload = payload
    }

    // Creates an app-backup document from a previously exported backup file URL.
    // A zip backup is extracted first; its folder stays in `assetsDirectory` until the import ends.
    init(contentsOf fileURL: URL) throws {
        if AppBackupZip.isZip(at: fileURL) {
            let opened = try AppBackupArchive.open(zipURL: fileURL)
            do {
                payload = try Self.decodePayload(from: opened.json)
                try Self.requireStemFiles(in: opened.directory, payload: payload)
            } catch {
                try? FileManager.default.removeItem(at: opened.directory)
                throw error
            }
            assetsDirectory = opened.directory
        } else {
            let data = try Data(contentsOf: fileURL)
            payload = try Self.decodePayload(from: data)
        }
    }

    // Deletes the extracted folder of an imported zip once the import is done or cancelled.
    func discardAssets() {
        if let assetsDirectory { try? FileManager.default.removeItem(at: assetsDirectory) }
    }

    // Rejects a zip whose listed stem files are not all present, before any store is touched.
    private static func requireStemFiles(in directory: URL, payload: AppBackupPayload) throws {
        let stems = AppBackupArchive.stemsDirectory(in: directory)
        for name in payload.extras?.stemFiles ?? [] where FileManager.default.fileExists(atPath: stems.appendingPathComponent(name).path) == false {
            throw AppBackupValidationError.invalid("the zip is missing the stem file \(name).")
        }
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
        if let archiveURL {
            return try FileWrapper(url: archiveURL, options: .immediate)
        }
        return FileWrapper(regularFileWithContents: try encodedPayload())
    }

    // The payload as the JSON that is a backup file, or the backup.json inside a zip.
    func encodedPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    // Decodes the current versioned app-backup payload format.
    // Version 1 backups (no audio) are accepted and upgraded — audioAttachments defaults to [].
    private static func decodePayload(from data: Data) throws -> AppBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(AppBackupPayload.self, from: data)
        guard (1...AppBackupPayload.currentVersion).contains(payload.version) else {
            throw NSError(
                domain: "Kioku.AppBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported app backup version \(payload.version). Expected version \(AppBackupPayload.currentVersion)."]
            )
        }
        try AppBackupValidator.validate(payload)
        return payload
    }
}
