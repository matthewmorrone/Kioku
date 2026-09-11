import Foundation
import AVFoundation

// On-device diagnostics for an alignment run, kept out of the algorithm file.
extension CTCForcedAligner {
    // Writes a timestamped breadcrumb + remaining memory budget to <Documents>/ctc-debug.log.
    // Flushed on every call, so if the OS kills the app mid-run the LAST line names the stage
    // that was running and the availMem trend shows whether memory was the cause. Best-effort;
    // never throws. `reset:true` starts a fresh log for the run.
    static func breadcrumb(_ stage: String, reset: Bool = false) {
        #if os(iOS)
        let availMB = Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        let availMB = -1
        #endif
        let line = "[\(Date())] \(stage) | availMem=\(availMB)MB\n"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = line.data(using: .utf8) else { return }
        let url = dir.appendingPathComponent("ctc-debug.log")
        if reset || FileManager.default.fileExists(atPath: url.path) == false {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
