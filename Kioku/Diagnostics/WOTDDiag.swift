import Foundation
import os

enum WOTDDiag {
    private nonisolated static let queue = DispatchQueue(label: "kioku.wotd.diag")
    private nonisolated static let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "wotd")

    nonisolated static func reset() {}

    nonisolated static func log(_ message: @autoclosure () -> String) {
        logger.notice("\(message(), privacy: .public)")
    }
}
