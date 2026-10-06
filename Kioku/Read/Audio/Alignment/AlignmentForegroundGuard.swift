import Foundation
import UIKit

// Keeps an alignment run in the foreground for as long as it can, and explains itself when it
// couldn't. A first-time alignment isolates the vocal stem on the GPU (a re-align reuses the
// cached stem), which iOS refuses a backgrounded app: in the background the separator switches to
// the CPU and checkpoints its progress, but iOS still suspends the app after a short grace period
// and may end it. The idle timer stops the common case, the screen locking itself mid-run; a
// failure that follows a trip to the background is reported as that rather than as whatever the
// interrupted layer threw.
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

    // True while the app is in the background. Asked before each vocal-isolation chunk: iOS
    // aborts GPU work from a backgrounded app, so the separator runs those chunks on the CPU.
    nonisolated static func isBackgrounded() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState == .background }
    }

    // The message to surface for `error`: the plain description, unless the app was backgrounded
    // during the run, in which case that is the cause worth naming whatever the aborted work said.
    func message(for error: Error) -> String {
        guard didBackground else { return error.localizedDescription }
        return "Alignment stopped while Kioku was in the background. Start it again: vocal isolation picks up where it left off."
    }
}
