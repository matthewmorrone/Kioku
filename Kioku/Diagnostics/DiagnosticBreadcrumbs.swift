import Foundation
import os.lock

// A tiny, signal-handler-safe ring buffer of recent diagnostic strings. Code on any thread can
// `drop(...)` a breadcrumb describing what it's about to do (and with what state); when a crash
// fires, CrashLogger.writeSignalCrash reads them back via `snapshot()` and embeds them in the
// `sig-*.json` record. This turns an opaque "SIGTRAP somewhere in sectionEdges" into "...and the
// last breadcrumb was: sublatticeEdges selBounds=3...3 segEdges.count=2 text.utf16=41" — i.e.
// the exact torn-state that caused it.
//
// Why a fixed C array + os_unfair_lock instead of [String]: the read happens inside a POSIX
// signal handler. Swift array growth allocates, and most locks aren't async-signal-safe.
// os_unfair_lock's trylock is safe enough for our "process is already dying" use, and the buffer
// never reallocates. Strings are still heap-allocated on `drop` (on the normal thread, which is
// fine); the signal-time read only copies existing references, no allocation.
nonisolated final class DiagnosticBreadcrumbs: @unchecked Sendable {
    private static let capacity = 32
    // nonisolated(unsafe): the compiler can't see that every access is serialized by `lock`
    // below, so we assert the safety ourselves. All reads/writes of buffer/nextIndex happen
    // under os_unfair_lock (or, in snapshot(), a trylock), making the access race-free.
    nonisolated(unsafe) private static var buffer = [String?](repeating: nil, count: capacity)
    nonisolated(unsafe) private static var nextIndex = 0
    nonisolated(unsafe) private static var lock = os_unfair_lock()

    // Record a breadcrumb. Cheap; safe to call on any thread. Keep messages short and include the
    // state values that matter for diagnosing torn/stale access (counts, lengths, bounds).
    static func drop(_ message: @autoclosure () -> String) {
        let msg = message()
        os_unfair_lock_lock(&lock)
        buffer[nextIndex] = msg
        nextIndex = (nextIndex + 1) % capacity
        os_unfair_lock_unlock(&lock)
    }

    // Returns the breadcrumbs in chronological order (oldest first). Called from the signal
    // handler; uses trylock so a crash that happened to fire mid-`drop` can't deadlock the
    // dying process — in that rare case we just return what we can without the lock.
    static func snapshot() -> [String] {
        let locked = os_unfair_lock_trylock(&lock)
        defer { if locked { os_unfair_lock_unlock(&lock) } }
        var result: [String] = []
        result.reserveCapacity(capacity)
        for offset in 0..<capacity {
            let idx = (nextIndex + offset) % capacity
            if let entry = buffer[idx] {
                result.append(entry)
            }
        }
        return result
    }
}
