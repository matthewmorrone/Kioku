import Darwin
import Foundation

// Records main-thread stalls during UI-test launches. XCUITest can only read or tap the app while
// its main thread answers accessibility queries, so a stall shows up in a test as "Timed out while
// evaluating UI query" with nothing to say what the app was doing. This pings the main queue from a
// background queue and writes each stall over a second to StartupTimer's log, between the startup
// marks around it, with the main thread's call stack sampled while it's stuck (a signal makes the
// main thread record its own backtrace). The UI tests attach that log. Debug builds and UI-test
// launches only.
nonisolated enum MainThreadStallWatch {
    private static let queue = DispatchQueue(label: "kioku.main-thread-stall-watch", qos: .utility)
    private static let frameCapacity: Int32 = 64
    // Written by the signal handler on the main thread, read on `queue` once `sampleReady` is set.
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    nonisolated(unsafe) private static var frameCount: Int32 = 0
    nonisolated(unsafe) private static var sampleReady = false
    // Set once on the main thread before the timer starts; read on `queue` after.
    nonisolated(unsafe) private static var mainThread: pthread_t?
    // Touched only on `queue`.
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var unansweredPingSentAt: CFAbsoluteTime?
    nonisolated(unsafe) private static var sampleRequested = false
    nonisolated(unsafe) private static var nextSampleAfter: CFAbsoluteTime = 1.5

    // Starts pinging the main queue when the UI tests launched the app; a no-op otherwise. Called
    // on the main thread, which it records as the thread to sample.
    static func startForUITests() {
        #if DEBUG
        guard UITestDictionaryInstaller.isUITestLaunch, Thread.isMainThread else { return }
        // Set before the timer exists, so the queue only ever reads it.
        mainThread = pthread_self()
        installSampleHandler()
        queue.async {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(250))
            source.setEventHandler { tick() }
            source.resume()
            timer = source
        }
        #endif
    }

    // SIGUSR2 makes the receiving thread write its own backtrace into `frames`. SA_RESTART so a
    // system call the main thread was blocked in carries on after the handler.
    private static func installSampleHandler() {
        frameCount = 0
        sampleReady = false
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            MainThreadStallWatch.frameCount = backtrace(MainThreadStallWatch.frames, MainThreadStallWatch.frameCapacity)
            MainThreadStallWatch.sampleReady = true
        }
        action.sa_flags = SA_RESTART
        if sigaction(SIGUSR2, &action, nil) != 0 {
            StartupTimer.mark("MainThreadStallWatch: sigaction failed (errno \(errno)); stalls are logged without stacks")
        }
    }

    // Every 250 ms: sends a ping when none is waiting; while one waits, samples the main thread's
    // stack at 1.5 s, 4.5 s, 13.5 s… into the stall and logs each sample once it arrives.
    private static func tick() {
        guard let sentAt = unansweredPingSentAt else {
            sendPing()
            return
        }
        let waited = CFAbsoluteTimeGetCurrent() - sentAt
        if sampleRequested {
            guard sampleReady else { return }
            sampleRequested = false
            logSample(waited: waited)
            nextSampleAfter *= 3
        } else if waited >= nextSampleAfter, let mainThread {
            sampleReady = false
            sampleRequested = true
            pthread_kill(mainThread, SIGUSR2)
        }
    }

    // Queues a ping on the main queue; its answer logs a wait over a second as a stall and clears
    // the way for the next ping.
    private static func sendPing() {
        let sentAt = CFAbsoluteTimeGetCurrent()
        unansweredPingSentAt = sentAt
        nextSampleAfter = 1.5
        DispatchQueue.main.async {
            let waited = CFAbsoluteTimeGetCurrent() - sentAt
            if waited > 1 {
                StartupTimer.mark(String(format: "main thread stalled %.0f ms", waited * 1000))
            }
            queue.async {
                unansweredPingSentAt = nil
                sampleRequested = false
            }
        }
    }

    // Writes the sampled main-thread stack to the startup log, one frame per line (symbol names
    // may be mangled; `swift demangle` reads them).
    private static func logSample(waited: CFAbsoluteTime) {
        let count = Int(frameCount)
        guard count > 0, let symbols = backtrace_symbols(frames, Int32(count)) else {
            StartupTimer.mark(String(format: "main thread stuck %.0f ms: no stack sampled", waited * 1000))
            return
        }
        defer { free(symbols) }
        let lines = (0..<count).compactMap { symbols[$0].map { String(cString: $0) } }
        StartupTimer.mark(String(format: "main thread stuck %.0f ms, stack:\n", waited * 1000) + lines.joined(separator: "\n"))
    }
}
