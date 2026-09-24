import Foundation
import UIKit

// Keeps an alignment run in the foreground for as long as it can, and explains itself when it
// couldn't. A first-time alignment isolates the vocal stem on the GPU (a re-align reuses the
// cached stem, which is why only the first run is affected), and iOS refuses GPU work from a
// backgrounded process — the command buffer is aborted and the run fails wherever it had got to.
// The idle timer is what stops the common case: the screen locking itself mid-run. Leaving the
// app by hand still ends the run, so a failure that follows a trip to the background is reported
// as that rather than as whatever the aborted layer threw.
@MainActor
final class AlignmentForegroundGuard {
    private var didBackground = false
    private var observer: NSObjectProtocol?

    // Starts holding the screen awake and watching for the app leaving the foreground.
    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBackground = true }
        }
    }

    // Releases the screen and stops watching. Idempotent: the caller's `defer` and a second
    // explicit call can't double-release, since the observer is cleared on the first.
    func end() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // Returns once the app is in the foreground, immediately when it already is. Awaited between
    // vocal-isolation chunks so the separator holds its partial result instead of submitting GPU
    // work iOS will abort; a process suspended while parked here resumes on the same chunk.
    nonisolated static func waitUntilForeground() async {
        while await MainActor.run(body: { UIApplication.shared.applicationState == .background }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // The observer unregisters itself from inside its own handler, on the main queue it
                // was registered against: a second didBecomeActive before the handler returned would
                // otherwise resume the same continuation twice, which traps.
                let token = ObserverToken()
                token.value = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    guard let observer = token.value else { return }
                    NotificationCenter.default.removeObserver(observer)
                    token.value = nil
                    continuation.resume()
                }
            }
        }
    }

    // The message to surface for `error`: the plain description, unless the app was backgrounded
    // during the run, in which case that is the cause worth naming whatever the aborted work said.
    func message(for error: Error) -> String {
        guard didBackground else { return error.localizedDescription }
        return "Alignment stopped because Kioku went to the background. Isolating the vocals needs the app on screen — start it again and leave Kioku open."
    }
}

// Mutable holder for the one-shot observer AlignmentForegroundGuard.waitUntilForeground registers,
// so its handler can unregister itself. Only ever touched on the main queue the observer runs on.
nonisolated private final class ObserverToken: @unchecked Sendable {
    var value: NSObjectProtocol?
}
