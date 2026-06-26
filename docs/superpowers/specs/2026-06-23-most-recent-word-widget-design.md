# Most Recent Word Widget — Design

**Date:** 2026-06-23
**Status:** Approved (pending implementation plan)

## Goal

Add a home-screen WidgetKit widget that displays the word from the most recent
Word of the Day (WOTD) notification the user received. The widget must stay
fresh without requiring the app to be launched, and tapping it opens that word's
detail in the app.

## Background

The app already schedules daily WOTD push notifications via
`WordOfTheDayScheduler` (`Kioku/Settings/WordOfTheDayScheduler.swift`). Each
notification is built in advance from a `(fireDate, surface, kana, meaning,
entryID)` tuple inside `scheduleUpcoming` (loop near line 171) using
`UNCalendarNotificationTrigger`, so the system delivers them while the app is
asleep. Notification taps already deep-link to the word detail via
`NotificationDeepLinkHandler` → `WordOfTheDayNavigation.shared.pendingTarget`,
which `ContentView` observes (`ContentView.swift:143`).

### Key constraints

- **Widgets run in a separate process.** A widget cannot read the app's
  in-memory state or its standard `UserDefaults`. The two processes share data
  only through an **App Group** container.
- **Notifications fire while the app is asleep**, so the app cannot reliably
  write "this word was just shown" at fire time.
- **The schedule is randomized** (`words.shuffled()`), so the widget cannot
  recompute which word maps to a given day — the app must hand it the resolved
  mapping.

## Decisions (resolved during brainstorming)

1. **Widget content:** surface + kana + meaning (mirrors the full notification
   body, e.g. `勉強【べんきょう】 study`). Tappable to open the word detail.
2. **"Most recent" semantics:** the word for the most recent *scheduled
   fire-time that has passed* ("today's word" once its time hits). The app
   mirrors the whole upcoming schedule into the App Group; the widget's own
   timeline replays it. No app launch required.
3. **Sizes:** `.systemSmall` and `.systemMedium` only. No Lock Screen / StandBy
   accessory widgets, no configurable intents (YAGNI).

## Architecture

### 1. New target & data sharing

- **New Widget Extension target** `KiokuWidget` (bundle id
  `matthewmorrone.Kioku.Widget`).
- **App Group** `group.matthewmorrone.Kioku` added to *both* the app and the
  widget targets' entitlements.
- A `UserDefaults(suiteName: "group.matthewmorrone.Kioku")` instance is the
  shared channel.
- A single shared source file (`WordOfTheDayMirror.swift`) is compiled into
  **both** targets — it holds the shared model and the read/write/clear helpers.
  No other app code is shared with the widget.

### 2. The mirror (what the app writes)

```swift
struct WordOfTheDayMirrorEntry: Codable, Equatable {
    let fireDate: Date
    let surface: String
    let kana: String?
    let meaning: String
    let entryID: Int64
}
```

- The app writes the full batch `[WordOfTheDayMirrorEntry]` to the shared suite
  whenever the WOTD schedule is (re)built in `scheduleUpcoming`, reusing the same
  `(fireDate, surface, kana, meaning, entryID)` values it already computes.
- The mirror is **cleared** whenever WOTD is disabled or unauthorized — i.e.
  everywhere `clearPendingWordOfTheDayRequests` is currently called. This
  eliminates the "stale word after disable" edge case.
- After any write or clear, the app calls
  `WidgetCenter.shared.reloadAllTimelines()` (guarded so it is a no-op where
  WidgetKit is unavailable).

### 3. Widget timeline

- The `TimelineProvider` reads the mirror, sorts entries by `fireDate`, and emits
  **one timeline entry per fire date**. WidgetKit advances the displayed word at
  each `fireDate` automatically, so the widget switches to the new word exactly
  when its notification fires.
- "Most recent" selection is a **pure function**: given the mirror and a
  reference date, return the entry with the greatest `fireDate <= now`. This is
  unit-testable in isolation.
- Empty mirror (no schedule, or WOTD disabled) → placeholder entry rendering an
  "Enable Word of the Day in Settings" prompt.

### 4. Widget view (content = surface + kana + meaning)

- Surface rendered large; kana small (above or beside the surface); meaning as
  secondary text.
- `.systemSmall`: meaning truncates to fit. `.systemMedium`: comfortable layout.
- `.widgetURL(URL(string: "kioku://word?id=\(entryID)&surface=\(surface)"))` so a
  tap opens the app to that word.

### 5. App-side deep link (reuses existing navigation)

- Add `.onOpenURL` to the `WindowGroup` / `ContentView` that parses
  `kioku://word?id=...&surface=...` into a `WordOfTheDayTarget` and assigns it to
  `WordOfTheDayNavigation.shared.pendingTarget` — the exact value
  `ContentView.swift:143` already navigates on. No new navigation logic.
- Register the `kioku` URL scheme via the app's Info.plist `CFBundleURLTypes`
  (the project currently generates Info.plist from build settings; the exact
  registration mechanism — `INFOPLIST_KEY_*` vs. an explicit Info.plist file — is
  verified during implementation, since widget-owned deep links may route to
  `onOpenURL` even without explicit scheme registration).

## Testing

Unit tests in `KiokuTests`, exercising the shared `WordOfTheDayMirror` file
(which is plain Foundation, no WidgetKit runtime needed):

- Most-recent-entry selection: returns nil for an empty mirror; picks the latest
  entry whose `fireDate <= now`; handles reference times before the first fire,
  exactly at a fire, and after the last fire.
- Mirror round-trip: encode then decode `[WordOfTheDayMirrorEntry]` via the
  shared-suite helpers and assert equality.
- Deep-link URL parsing: `kioku://word?id=123&surface=勉強` parses to
  `WordOfTheDayTarget(entryID: 123, surface: "勉強")`; malformed URLs return nil.

## Out of scope (YAGNI)

- Notification Service Extension / true delivery confirmation.
- Lock Screen / StandBy accessory widgets.
- Configurable widget intents (size or word-source selection).
- Large widget size.

These can be added later without reworking the mirror-based foundation.
