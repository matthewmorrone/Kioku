import Foundation

// Tracks whether a Segmenter has its dictionary yet, and holds callers until it does. The app
// publishes an empty placeholder Segmenter at launch and fills it in once the dictionary loads
// (Segmenter.reconfigure); anything that segments in between gets one-character pieces and no
// readings, and features that cache their result keep that until the next launch. Thread-safe:
// segmentation runs on background tasks while reconfigure runs on the main actor.
nonisolated final class SegmenterLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Starts open when the segmenter is built straight from a loaded dictionary.
    init(loaded: Bool) {
        self.loaded = loaded
    }

    // Opens the gate and releases everyone waiting on it. Later calls do nothing.
    func markLoaded() {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard loaded == false else { return [] }
            loaded = true
            let pending = waiters
            waiters = []
            return pending
        }
        for waiter in released {
            waiter.resume()
        }
    }

    // Returns once the dictionary is loaded; immediately when it already is.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen: Bool = lock.withLock {
                if loaded { return true }
                waiters.append(continuation)
                return false
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}
