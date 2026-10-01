import Foundation

// Tap-pipeline diagnostic timer. The instant the gesture recognizer fires we call
// `TapDiagnostics.beginTap()`, and every subsequent checkpoint along the path to the
// lookup sheet calls `TapDiagnostics.mark(_:)`. Each mark logs the elapsed time since the tap
// began (AppLog, Dictionary Loading / Lookup) so the slow step shows up unambiguously; Debug builds
// also get AppLog's on-disk mirror, so a slow tap can be reproduced at leisure and pulled afterward.
nonisolated enum TapDiagnostics {
    nonisolated(unsafe) static var startTime: CFAbsoluteTime = 0
    nonisolated(unsafe) static var isActive: Bool = false

    // Called the instant the tap recognizer fires; resets the elapsed-time clock so every
    // subsequent `mark` reports time-since-this-tap.
    static func beginTap() {
        startTime = CFAbsoluteTimeGetCurrent()
        isActive = true
        AppLog.debug(.dictionary, "TAP[+0.000s] BEGIN — tap recognized")
    }

    // Logs one checkpoint with elapsed time since `beginTap`. No-op outside an active tap
    // so background work (audio playback, scroll animation) doesn't spam the log.
    static func mark(_ label: String) {
        guard isActive else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        AppLog.debug(.dictionary, String(format: "TAP[+%.3fs] %@", elapsed, label))
    }

    // Closes the current tap measurement so subsequent calls are silent until the next
    // `beginTap`. Defaults the label to "END" so callers don't have to repeat themselves.
    static func endTap(_ label: String = "END") {
        guard isActive else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        AppLog.debug(.dictionary, String(format: "TAP[+%.3fs] %@", elapsed, label))
        isActive = false
    }
}
