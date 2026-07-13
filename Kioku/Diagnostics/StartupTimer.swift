import Foundation
import os.log

// Provides structured startup timing, written to both stdout and a Caches file (same pattern
// as TapDiagnostics — see that file's header for why: live `devicectl --console` capture is
// unreliable and loses in-app navigation on every relaunch, while the file survives normally
// and can be pulled after the fact with:
//   xcrun devicectl device copy from --device <id> --source Caches/startup-timing.log \
//     --domain-type appDataContainer --domain-identifier matthewmorrone.Kioku --destination <path>
nonisolated enum StartupTimer {
    nonisolated static let log = OSLog(subsystem: "com.kioku.startup", category: "performance")
    private static let launchStart = CFAbsoluteTimeGetCurrent()
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    // Elapsed wall-clock milliseconds since the startup timer was initialized.
    private static var elapsedSinceLaunchMs: Double {
        (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
    }

    // Lazily opens (creating if needed) the on-disk log, truncating any prior run's contents.
    private static func openFileHandleIfNeeded() -> FileHandle? {
        if let fileHandle { return fileHandle }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logURL = cachesURL.appendingPathComponent("startup-timing.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        fileHandle = handle
        return handle
    }

    // Writes one line to both stdout and the on-disk log.
    private static func emit(_ line: String) {
        print(line)
        guard let handle = openFileHandleIfNeeded(), let data = (line + "\n").data(using: .utf8) else {
            return
        }
        handle.write(data)
    }

    // Measures a synchronous block, logging elapsed ms since launch and the block's own duration.
    nonisolated static func measure<T>(_ label: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        emit(String(format: "[Startup +%.1fms] %@: %.1fms", elapsedSinceLaunchMs, label, elapsed))
        return result
    }

    // Logs a single timestamp marker for async boundaries and lifecycle events.
    nonisolated static func mark(_ label: String) {
        emit(String(format: "[Startup +%.1fms] %@", elapsedSinceLaunchMs, label))
    }
}
