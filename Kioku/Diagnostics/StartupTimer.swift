import Foundation
import os.log

// Provides structured startup timing via os_signpost and console output.
// Filter in Console.app by subsystem "com.kioku.startup" to see all entries.
nonisolated enum StartupTimer {
    nonisolated static let log = OSLog(subsystem: "com.kioku.startup", category: "performance")
    private static let launchStart = CFAbsoluteTimeGetCurrent()

    // Elapsed wall-clock milliseconds since the startup timer was initialized.
    private static var elapsedSinceLaunchMs: Double {
        (CFAbsoluteTimeGetCurrent() - launchStart) * 1000
    }

    // Measures a synchronous block, logging elapsed ms to console and emitting signpost intervals.
    nonisolated static func measure<T>(_ label: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        // Logging disabled.
        // os_signpost(.begin, log: log, name: "Startup", "%{public}s", label)
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        _ = elapsed
        // Logging disabled.
        // os_signpost(.end, log: log, name: "Startup", "%{public}s", label)
        // os_log(
        //     .info,
        //     log: log,
        //     "[Startup +%.1f ms] %{public}s: %.1f ms",
        //     elapsedSinceLaunchMs,
        //     label,
        //     elapsed
        // )
        return result
    }

    // Logs a single timestamp marker for async boundaries and lifecycle events.
    nonisolated static func mark(_ label: String) {
        _ = label
        // Logging disabled.
        // os_log(.info, log: log, "[Startup +%.1f ms] %{public}s", elapsedSinceLaunchMs, label)
    }
}
