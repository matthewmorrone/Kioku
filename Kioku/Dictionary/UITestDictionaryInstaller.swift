import Foundation

// UI tests (KiokuUITests) run the app on a fresh simulator, where the dictionary would first be
// downloaded (~384 MB). They pass the repo's Resources/dictionary.sqlite instead, as the launch
// environment's KIOKU_UITEST_DICTIONARY; a simulator app can read the Mac's files, so the app copies
// it into its install location and marks it as the pinned release. Everything after runs the real
// code path. Debug builds only: a release build ignores the variable.
nonisolated enum UITestDictionaryInstaller {
    static let environmentKey = "KIOKU_UITEST_DICTIONARY"

    // True when KiokuUITests launched the app (it always passes the dictionary). Debug builds only.
    static var isUITestLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[environmentKey] != nil
        #else
        return false
        #endif
    }

    // Installs the dictionary the UI tests named, when they named one and it isn't installed yet.
    // Failures are logged; the app then falls back to its normal download.
    static func installIfRequested() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment[environmentKey], DictionaryDownloadManager.isInstalled == false else { return }
        do {
            try FileManager.default.createDirectory(at: DictionaryDownloadManager.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: DictionaryDownloadManager.installedDatabaseURL.path) {
                try FileManager.default.removeItem(at: DictionaryDownloadManager.installedDatabaseURL)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: DictionaryDownloadManager.installedDatabaseURL)
            try DictionaryDownloadManager.releaseTag.write(to: DictionaryDownloadManager.installedReleaseMarkerURL, atomically: true, encoding: .utf8)
            AppLog.info(.dictionaryDownload, "UI test dictionary installed from \(path)")
        } catch {
            AppLog.error(.dictionaryDownload, "UI test dictionary install failed: \(error)")
        }
        #endif
    }
}
