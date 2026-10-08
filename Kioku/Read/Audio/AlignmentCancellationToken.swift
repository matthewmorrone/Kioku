import Foundation

// Thread-safe cancellation flag for alignment. The @Observable Bool drives UI; this token is
// what we hand to the @Sendable cancellationCheck closure so the aligner can poll it from
// inference threads without crossing actor isolation. cancelAlignment() flips both.
nonisolated final class AlignmentCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    // Thread-safe read of the cancellation flag, polled from the aligner's background work.
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }
    // Signals cancellation so the aligner's next cancellation check returns true.
    func cancel() {
        lock.lock(); _isCancelled = true; lock.unlock()
    }
    // Clears the flag before starting a new alignment run.
    func reset() {
        lock.lock(); _isCancelled = false; lock.unlock()
    }
}
