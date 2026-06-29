import Foundation

// File-based sink for the LLM correction pipeline's debug output, used so
// `[JMdictTool]` and `[AppleIntelligence]` events can be pulled off the
// device via `xcrun devicectl device copy from` instead of requiring
// Console.app on a Mac that happens to be attached at the right moment.
//
// File: `Library/Caches/llm-debug.log` in the app's container.
// Pull:
//   xcrun devicectl device copy from \
//     --device <udid> --domain-type appDataContainer \
//     --domain-identifier matthewmorrone.Kioku \
//     --source Library/Caches/llm-debug.log \
//     --destination ./llm-debug.log
// All static storage is `nonisolated` so the sink can be reached from the
// non-isolated async paths (Tool.call, AppleIntelligenceCorrectionClient's
// per-line task body) without an unnecessary main-actor hop. The NSLock is
// `Sendable` for cross-actor reuse; the DateFormatter and URL are immutable
// references and thread-safe for read-only use.
enum LLMDebugLog {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    nonisolated(unsafe) private static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("llm-debug.log")
    }()
    // Cap the on-device log size so multi-hour debugging sessions don't fill
    // the caches directory. When the file grows past this, the next write
    // truncates and starts fresh — losing history is acceptable for a debug
    // sink that's meant to capture the latest run.
    nonisolated private static let maxBytes: Int = 256 * 1024

    // Appends one timestamped line to the log file. Best-effort: I/O errors
    // are swallowed because losing a debug line is strictly better than
    // crashing the correction pipeline. Explicitly nonisolated so the
    // non-isolated async Tool.call() path can use it under Swift 6 strict
    // concurrency without a MainActor hop.
    nonisolated static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        // Print to console too so attached Xcode users still see it; the file
        // sink is purely additive.
        print(message)

        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        let path = fileURL.path
        let attrs = try? fm.attributesOfItem(atPath: path)
        let currentSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        if fm.fileExists(atPath: path) == false || currentSize > maxBytes {
            try? data.write(to: fileURL, options: .atomic)
            return
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // Removes the log file. Not wired to a UI affordance; useful for tests
    // or a future debug toggle that wants a clean slate per run.
    nonisolated static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
