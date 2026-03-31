import Foundation
import os.log

// Provides structured startup timing via os_signpost and console output.
// Filter in Console.app by subsystem "com.kioku.startup" to see all entries.
enum StartupTimer {
    static let log = OSLog(subsystem: "com.kioku.startup", category: "performance")

    // Measures a synchronous block, logging elapsed ms to console and emitting signpost intervals.
    static func measure<T>(_ label: String, block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        os_signpost(.begin, log: log, name: "Startup", "%{public}s", label)
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        os_signpost(.end, log: log, name: "Startup", "%{public}s", label)
        os_log(.info, log: log, "[Startup] %{public}s: %.1f ms", label, elapsed)
        return result
    }

    // Logs a single timestamp marker for async boundaries and lifecycle events.
    static func mark(_ label: String) {
        os_log(.info, log: log, "[Startup] %{public}s", label)
    }
}
