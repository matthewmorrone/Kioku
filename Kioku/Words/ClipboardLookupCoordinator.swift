import Combine
import SwiftUI
import UIKit

// Decides whether to surface a clipboard-lookup prompt on app focus, and produces the looked-up text.
// Persists the last-seen changeCount so the banner only fires when the clipboard genuinely changed
// since the previous session, not on every cold launch.
@MainActor
final class ClipboardLookupCoordinator: ObservableObject {
    @Published private(set) var hasPendingClipboard = false
    @AppStorage("clipboardLookup.lastSeenChangeCount") private var lastSeenChangeCount: Int = -1

    // Checks the pasteboard without reading its content; flips `hasPendingClipboard` when a new lookup is worth offering.
    func checkClipboard() {
        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastSeenChangeCount else { return }
        // hasStrings / hasURLs are banner-free type probes — they don't trigger iOS's "Pasted from X" notice.
        // Skip URL-only clipboards (probably shared links, not lookup targets).
        guard pasteboard.hasStrings, pasteboard.hasURLs == false else {
            lastSeenChangeCount = currentChangeCount
            return
        }
        hasPendingClipboard = true
    }

    // Reads the pasteboard string (this triggers iOS's "Pasted from X" banner) and marks the change consumed.
    func consumeClipboard() -> String? {
        let pasteboard = UIPasteboard.general
        defer {
            lastSeenChangeCount = pasteboard.changeCount
            hasPendingClipboard = false
        }
        guard let raw = pasteboard.string else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        // Cap length so a pasted novel doesn't blow up the search field.
        return String(trimmed.prefix(200))
    }

    // Acknowledges the current clipboard state without reading it — used when the user dismisses the prompt.
    func dismiss() {
        lastSeenChangeCount = UIPasteboard.general.changeCount
        hasPendingClipboard = false
    }
}
