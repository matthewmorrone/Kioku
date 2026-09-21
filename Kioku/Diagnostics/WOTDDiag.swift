import Foundation
import os

enum WOTDDiag {
    private nonisolated static let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "wotd")

    // Retained as a launch hook for the notification diagnostic call site; release builds no longer persist a file trace.
    nonisolated static func reset() {}

    // Emits notification diagnostic breadcrumbs only to the unified logging system.
    nonisolated static func log(_ message: @autoclosure () -> String) {
        logger.notice("\(message(), privacy: .public)")
    }
}
