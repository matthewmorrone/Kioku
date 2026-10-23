import Foundation

// Lays out and reads the zip form of a backup: `backup.json` (the payload, with audio bytes left
// out), `audio/<attachment UUID>.<ext>` for each attachment, and `stems/<file>` for the cached
// vocal stems. A backup without audio or stems stays a single JSON file and never comes through here.
nonisolated enum AppBackupArchive {
    static let jsonName = "backup.json"
    static let audioFolder = "audio"
    static let stemsFolder = "stems"

    // One audio file to place in the archive: where it is now and the name it gets under audio/.
    struct AudioFile {
        let source: URL
        let name: String
    }

    // Stages the files in a temp folder, zips it, and returns the zip's URL. The staging folder is
    // removed either way; the caller owns the returned file.
    static func build(json: Data, audio: [AudioFile], stemsDirectory: URL?, stemFiles: [String]) throws -> URL {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory.appendingPathComponent("kioku-export-\(UUID().uuidString)", isDirectory: true)
        let staging = temp.appendingPathComponent("kioku-backup", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try json.write(to: staging.appendingPathComponent(jsonName))

        let audioDirectory = staging.appendingPathComponent(audioFolder, isDirectory: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        for file in audio {
            try fileManager.copyItem(at: file.source, to: audioDirectory.appendingPathComponent(file.name))
        }

        let stagedStems = staging.appendingPathComponent(stemsFolder, isDirectory: true)
        try fileManager.createDirectory(at: stagedStems, withIntermediateDirectories: true)
        if let stemsDirectory {
            for name in stemFiles {
                try fileManager.copyItem(at: stemsDirectory.appendingPathComponent(name), to: stagedStems.appendingPathComponent(name))
            }
        }

        let zipURL = temp.appendingPathComponent("kioku-export.zip")
        try AppBackupZip.zip(directory: staging, to: zipURL)
        return zipURL
    }

    // Extracts a zip backup into a fresh temp folder and returns that folder plus the payload JSON.
    // The folder is deleted again if the archive has no readable backup.json.
    static func open(zipURL: URL) throws -> (directory: URL, json: Data) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("kioku-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try AppBackupZip.extract(zipURL: zipURL, to: directory)
            guard let json = try? Data(contentsOf: directory.appendingPathComponent(jsonName)) else {
                throw AppBackupValidationError.invalid("the zip has no backup.json.")
            }
            return (directory, json)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    // The extracted audio file for an attachment, nil when the zip carried none for it.
    static func audioFile(for attachmentID: UUID, in directory: URL) -> URL? {
        let folder = directory.appendingPathComponent(audioFolder, isDirectory: true)
        return OptionalFileRead.contents(of: folder, logAs: .backup)
            .first { $0.deletingPathExtension().lastPathComponent == attachmentID.uuidString }
    }

    // The folder holding the extracted stem files.
    static func stemsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(stemsFolder, isDirectory: true)
    }
}
