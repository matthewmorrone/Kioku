import Foundation
import os

// File-based sink shared by every AppLog feature, used so raw request/response content can be
// pulled off a physical device without Console.app or Xcode happening to be attached at the
// right moment — the scenario this whole logging system was requested for. All storage is
// `nonisolated` so it can be reached from non-isolated async contexts (URLSessionDelegate
// callbacks, NWConnection completion handlers, Task.detached bodies) without a MainActor hop.
// DEBUG-only: unlike os_log's `.private` redaction, this sink writes plaintext, so it must never
// end up in a release/App-Store build's container.
enum AppLogFileSink {
    nonisolated private static let lock = NSLock()
    nonisolated private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    // File: `Library/Caches/app-debug.log` in the app's container. Pull with:
    //   xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
    //     --domain-identifier matthewmorrone.Kioku --source Library/Caches/app-debug.log \
    //     --destination ./app-debug.log
    nonisolated static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("app-debug.log")
    }()
    // Cap so a long debugging session doesn't fill the caches directory. Past this, the next
    // write truncates and starts fresh — losing history is acceptable for a sink meant to
    // capture the latest run.
    nonisolated private static let maxBytes: Int = 1024 * 1024

    // Appends one timestamped, feature-tagged line to the shared log file, truncating past
    // maxBytes so a long session can't grow it unbounded. Lock-protected since callers can arrive
    // from any thread (network delegates, background tasks) concurrently.
    nonisolated static func write(feature: LogFeature, level: OSLogType, text: String) {
        lock.lock()
        defer { lock.unlock() }

        let ts = formatter.string(from: Date())
        let line = "[\(ts)] [\(feature.rawValue)] \(levelTag(level)) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        let path = fileURL.path
        let attrs = try? fm.attributesOfItem(atPath: path)
        let currentSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        if fm.fileExists(atPath: path) == false || currentSize > maxBytes {
            try? data.write(to: fileURL, options: .atomic)
            return
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // Renders an OSLogType as a short tag for the on-disk line, since the raw enum isn't
    // human-readable in a plain-text file the way os.Logger's own formatting would be.
    nonisolated private static func levelTag(_ level: OSLogType) -> String {
        switch level {
        case .error, .fault: return "ERROR"
        case .info: return "INFO"
        default: return "DEBUG"
        }
    }

    // Removes the on-disk mirror. Wired to the "Clear Log File" button in Settings → Debug Logs.
    nonisolated static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // Current file size in bytes, for display in Settings → Debug Logs. Returns 0 if the
    // file doesn't exist yet (nothing has logged since the last clear/install).
    nonisolated static func currentSizeBytes() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
}
