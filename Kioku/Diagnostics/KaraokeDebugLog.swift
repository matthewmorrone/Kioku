import Foundation
import os

// Append-only diagnostic log for TextGrid / karaoke debugging. Lines are timestamped and written
// to ~/Documents/karaoke-debug.log on device so they can be pulled back via:
//   xcrun devicectl device copy from --domain-type appDataContainer
//     --domain-identifier matthewmorrone.Kioku
//     --source karaoke-debug.log --destination /tmp/karaoke-debug.log
// Also routed through os.Logger for live Console.app inspection. Thread-safe via a serial queue
// so the playback observer can call it from its publisher callbacks without ordering hazards.
enum KaraokeDebugLog {
    // All four constants are referenced from `nonisolated` static methods, so they must also be
    // nonisolated under the project's default-MainActor isolation. DispatchQueue, Logger, URL,
    // and DateFormatter are all Sendable in this toolchain so plain `nonisolated` is enough.
    private nonisolated static let queue = DispatchQueue(label: "kioku.karaoke.debuglog")
    private nonisolated static let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "karaoke")
    private nonisolated static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("karaoke-debug.log")
    }()
    private nonisolated static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // Writes one timestamped line to the on-disk log and emits the same string to the unified log.
    // Failures are swallowed — diagnostics must never crash the audio path. Cue/note previews are
    // logged with .public privacy, which would leak user subtitle and note content to device-log
    // collection and the on-disk file in release builds. Compile this whole path out unless DEBUG
    // is set so production builds emit nothing and never create the log file.
    nonisolated static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        logger.debug("\(text, privacy: .public)")
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
        #endif
    }

    // Truncates the log file. Called at app start so each run starts clean. No-op in release
    // because release builds never write to the file in the first place.
    nonisolated static func reset() {
        #if DEBUG
        queue.async {
            try? Data().write(to: fileURL, options: .atomic)
        }
        #endif
    }
}
