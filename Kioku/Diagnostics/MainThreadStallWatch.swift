import Foundation

// Records main-thread stalls during UI-test launches. XCUITest can only read or tap the app while
// its main thread answers accessibility queries, so a stall shows up in a test as "Timed out while
// evaluating UI query" with nothing to say what the app was doing. This pings the main queue from a
// background queue and writes each stall over a second to StartupTimer's log, between the startup
// marks around it; the UI tests attach that log. Debug builds and UI-test launches only.
nonisolated enum MainThreadStallWatch {
    private static let queue = DispatchQueue(label: "kioku.main-thread-stall-watch", qos: .utility)
    // Touched only on `queue`.
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var unansweredPingSentAt: CFAbsoluteTime?

    // Starts pinging the main queue when the UI tests launched the app; a no-op otherwise.
    static func startForUITests() {
        #if DEBUG
        guard UITestDictionaryInstaller.isUITestLaunch else { return }
        queue.async {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(250))
            source.setEventHandler { ping() }
            source.resume()
            timer = source
        }
        #endif
    }

    // Sends one ping unless the last is still waiting; the main queue's answer reports how long
    // it waited, and a wait over a second is logged as a stall.
    private static func ping() {
        guard unansweredPingSentAt == nil else { return }
        let sentAt = CFAbsoluteTimeGetCurrent()
        unansweredPingSentAt = sentAt
        DispatchQueue.main.async {
            let waited = CFAbsoluteTimeGetCurrent() - sentAt
            if waited > 1 {
                StartupTimer.mark(String(format: "main thread stalled %.0f ms", waited * 1000))
            }
            queue.async { unansweredPingSentAt = nil }
        }
    }
}
