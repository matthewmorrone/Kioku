import Foundation

// Utilities the audio import paths share (transcription, lyric alignment); none of them touch
// ReadView state.
enum AudioTranscriptionHelpers {

    // Copies an imported audio file into a temporary location so transcription and alignment can
    // safely access it after file-importer scope ends. The copy is wrapped in NSFileCoordinator's reading
    // intent so iCloud Drive entries that are evicted (catalog present, bytes not downloaded)
    // are pulled down on demand before copyItem touches them — without this the picker hands
    // back a stub URL, copyItem sees no bytes, and Foundation throws
    // `NSFileNoSuchFileError: The file "X" doesn't exist.` with the bare original filename.
    static func copyImportedAudioToTemporaryLocation(_ sourceURL: URL) throws -> URL {
        let didStartAccessingSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }

        // Coordinated read triggers iCloud download (and serialises against any concurrent
        // Files-app writer). The closure receives the downloaded URL — for a local file this is
        // the same path, for an evicted iCloud file iOS materialises the bytes before invoking.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var copyError: Error?
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordError) { downloadedURL in
            do {
                try FileManager.default.copyItem(at: downloadedURL, to: temporaryURL)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }

        return temporaryURL
    }
}
