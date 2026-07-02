import UIKit

// A UIApplication background-task assertion that keeps a long-running operation alive for a
// window after the app is backgrounded, instead of the OS suspending it immediately (and
// SIGKILLing with 0xDEAD10CC for holding a resource lock while suspended). Used to bracket the
// three heavy operations that a user is likely to trigger and then switch away from: on-device
// vocal stemming + transcription, forced alignment, and network LLM requests.
//
// Holder-based (rather than a raw UIBackgroundTaskIdentifier) so the OS expiration handler and
// the caller's `defer` share one identifier and never double-end it. All identifier access is
// MainActor-confined; the expiration handler is invoked by UIKit on the main thread.
final class BackgroundTaskHolder: @unchecked Sendable {
    private var id: UIBackgroundTaskIdentifier = .invalid

    // Begins an assertion whose expiration handler releases it if the OS reclaims the time before
    // the work finishes — required, or the app is terminated for leaving the assertion dangling.
    @MainActor
    static func begin(_ name: String) -> BackgroundTaskHolder {
        let holder = BackgroundTaskHolder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak holder] in
            // UIKit invokes the expiration handler on the main thread.
            MainActor.assumeIsolated { holder?.end() }
        }
        return holder
    }

    // Ends the assertion. Idempotent: repeated calls (expiration handler + caller defer) are no-ops.
    @MainActor
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }

    // Fire-and-forget end for a synchronous `defer` inside an async function.
    func endDetached() {
        Task { @MainActor in self.end() }
    }
}
