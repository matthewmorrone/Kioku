import Foundation
import os

// TEMPORARY diagnostic logger for the Word-of-the-Day notification deep-link investigation.
// Append-only, written UNCONDITIONALLY (not DEBUG-gated) to ~/Documents/wotd-debug.log so it can
// be pulled off the device regardless of build configuration via:
//   xcrun devicectl device copy from --device Monoceros \
//     --domain-type appDataContainer --domain-identifier matthewmorrone.Kioku \
//     --source wotd-debug.log --destination /tmp/wotd-debug.log
// Only logs non-sensitive scalars (entry IDs, booleans, route case names) — never headword/meaning
// text — so leaving it on briefly is harmless. Remove once the deep-link bug is root-caused.
enum WOTDDiag {
    private nonisolated static let queue = DispatchQueue(label: "kioku.wotd.diag")
    private nonisolated static let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "wotd")
    private nonisolated static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("wotd-debug.log")
    }()
    private nonisolated static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // Truncates the log so each launch starts clean — important because a notification can
    // cold-launch the app, and a per-run trace is far easier to read than an append-only pile.
    nonisolated static func reset() {
        queue.async {
            try? Data().write(to: fileURL, options: .atomic)
        }
    }

    // Writes one timestamped, non-sensitive breadcrumb line to the on-disk log and unified log.
    nonisolated static func log(_ message: @autoclosure () -> String) {
        let text = message()
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        logger.notice("\(text, privacy: .public)")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
