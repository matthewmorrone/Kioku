import Combine
import SwiftUI
import UIKit

// Decides whether to surface a clipboard-lookup prompt on app focus, and produces the looked-up text.
// Persists the last-seen changeCount so the banner only fires when the clipboard genuinely changed
// since the previous session, not on every cold launch.
//
// Privacy note: filtering for Japanese content requires reading `pasteboard.string`, which
// triggers iOS's "Pasted from X" notification. That's the trade-off for showing OUR banner
// only when the clipboard actually contains Japanese — without reading, iOS exposes only
// the banner-free type probes (`hasStrings`, `hasURLs`) which can't see the content.
// The read string is cached between `checkClipboard` and `consumeClipboard` so the user
// only triggers one iOS access per clipboard change, not two.
@MainActor
final class ClipboardLookupCoordinator: ObservableObject {
    @Published private(set) var hasPendingClipboard = false
    @AppStorage("clipboardLookup.lastSeenChangeCount") private var lastSeenChangeCount: Int = -1

    // Cached trimmed clipboard string captured at check time so consume doesn't have to
    // hit the pasteboard a second time (which would fire iOS's "Pasted from" banner again).
    private var pendingClipboardText: String?

    // Reads the pasteboard, filters non-Japanese content, and flips `hasPendingClipboard`
    // only when a lookup-worthy Japanese string is present. Triggers iOS's "Pasted from"
    // banner because content access is required to apply the script filter.
    func checkClipboard() {
        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastSeenChangeCount else { return }
        // Skip URL-only clipboards (probably shared links, not lookup targets) via the
        // banner-free type probe — saves a content read for the common copy-a-link case.
        guard pasteboard.hasStrings, pasteboard.hasURLs == false else {
            lastSeenChangeCount = currentChangeCount
            return
        }
        guard let raw = pasteboard.string else {
            lastSeenChangeCount = currentChangeCount
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, ScriptClassifier.containsJapanese(trimmed) else {
            // Mark the change consumed so we don't re-read this clipboard on the next focus.
            lastSeenChangeCount = currentChangeCount
            return
        }
        // Cap length so a pasted novel doesn't blow up the search field.
        pendingClipboardText = String(trimmed.prefix(200))
        hasPendingClipboard = true
    }

    // Returns the cached clipboard text (read once during `checkClipboard`) and marks the
    // change consumed. No additional pasteboard access — the iOS banner already fired at check time.
    func consumeClipboard() -> String? {
        defer {
            lastSeenChangeCount = UIPasteboard.general.changeCount
            hasPendingClipboard = false
            pendingClipboardText = nil
        }
        return pendingClipboardText
    }

    // Acknowledges the current clipboard state without reading it — used when the user dismisses the prompt.
    func dismiss() {
        lastSeenChangeCount = UIPasteboard.general.changeCount
        hasPendingClipboard = false
        pendingClipboardText = nil
    }
}
