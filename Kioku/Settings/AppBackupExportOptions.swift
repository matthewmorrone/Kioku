import Foundation

// What the user chose to put in an export beyond the always-included data.
nonisolated struct AppBackupExportOptions {
    // The attached audio files; makes the backup a zip instead of a single JSON file.
    var includeAudio = false
    // The cached isolated vocals and instrumentals; also makes the backup a zip.
    var includeStems = false
    // The remote-service API keys, stored in the backup file as plain text.
    var includeAPIKeys = false
}
