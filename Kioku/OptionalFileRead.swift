import Foundation

// Reads of files and directories that may legitimately not exist yet (a cache entry, a sidecar,
// a directory created on first write). Absence returns nil/empty quietly; a file that exists but
// can't be read is logged under the caller's feature, so it doesn't pass for "never written".
nonisolated enum OptionalFileRead {
    // The file's bytes, or nil when it is absent or unreadable (the latter is logged).
    static func data(at url: URL, logAs feature: LogFeature) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            AppLog.error(feature, "\(url.lastPathComponent) unreadable — \(error.localizedDescription)")
            return nil
        }
    }

    // The directory's entries, or empty when it is absent or unreadable (the latter is logged).
    static func contents(of directory: URL, logAs feature: LogFeature) -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            AppLog.error(feature, "\(directory.lastPathComponent)/ unreadable — \(error.localizedDescription)")
            return []
        }
    }
}
