import Foundation

// Tap-pipeline diagnostic timer. The instant the gesture recognizer fires we call
// `TapDiagnostics.beginTap()`, and every subsequent checkpoint along the path to the
// lookup sheet calls `TapDiagnostics.mark(_:)`. Each mark prints the elapsed time
// since the tap began so the slow step shows up unambiguously in the device console.
//
// Also appends every line to a file in Caches (tap-diagnostics.log) — live console
// capture via `devicectl device process launch --console` requires a fresh app launch,
// which resets in-app navigation and forces a race against a short capture window. The
// file survives across the app's normal lifetime, so a bug can be reproduced at leisure
// and the log pulled afterward with:
//   xcrun devicectl device copy from --device <id> --source Caches/tap-diagnostics.log \
//     --domain-type appDataContainer --domain-identifier matthewmorrone.Kioku --destination <path>
nonisolated enum TapDiagnostics {
    nonisolated(unsafe) static var startTime: CFAbsoluteTime = 0
    nonisolated(unsafe) static var isActive: Bool = false
    nonisolated(unsafe) private static var fileHandle: FileHandle?

    // Lazily opens (creating if needed) the on-disk log, truncating any prior run's
    // contents so each fresh app launch starts a clean file instead of growing forever.
    private static func openFileHandleIfNeeded() -> FileHandle? {
        if let fileHandle { return fileHandle }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logURL = cachesURL.appendingPathComponent("tap-diagnostics.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        fileHandle = handle
        return handle
    }

    // Writes one line to both stdout (for live --console capture) and the on-disk log.
    private static func emit(_ line: String) {
        print(line)
        guard let handle = openFileHandleIfNeeded(), let data = (line + "\n").data(using: .utf8) else {
            return
        }
        handle.write(data)
    }

    // Called the instant the tap recognizer fires; resets the elapsed-time clock so every
    // subsequent `mark` reports time-since-this-tap.
    static func beginTap() {
        startTime = CFAbsoluteTimeGetCurrent()
        isActive = true
        emit("TAP[+0.000s] BEGIN — tap recognized")
    }

    // Logs one checkpoint with elapsed time since `beginTap`. No-op outside an active tap
    // so background work (audio playback, scroll animation) doesn't spam the console.
    static func mark(_ label: String) {
        guard isActive else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        emit(String(format: "TAP[+%.3fs] %@", elapsed, label))
    }

    // Closes the current tap measurement so subsequent calls are silent until the next
    // `beginTap`. Defaults the label to "END" so callers don't have to repeat themselves.
    static func endTap(_ label: String = "END") {
        guard isActive else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        emit(String(format: "TAP[+%.3fs] %@", elapsed, label))
        isActive = false
    }
}
