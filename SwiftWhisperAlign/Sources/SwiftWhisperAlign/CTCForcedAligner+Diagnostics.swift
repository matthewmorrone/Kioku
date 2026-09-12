import Foundation
import AVFoundation

// On-device diagnostics for an alignment run, kept out of the algorithm file.
extension CTCForcedAligner {
    // [DEBUG] Writes one intermediate (the raw pre-pinning emission matrix, the per-line romaji the
    // app fed the Viterbi) to Documents/ctc-debug/<stem key>.<name>, so a device miss can be replayed
    // on the Mac against the reference pipeline to see which input differs.
    static func debugDump(_ data: Data, name: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("ctc-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name))
    }

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
