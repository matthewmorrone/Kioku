import Foundation
import os

// Single entry point for feature-scoped logging across the app. Every call site names the
// LogFeature it belongs to, so Console/`log stream` filtering on
// `subsystem:matthewmorrone.Kioku category:<feature>` isolates exactly one feature's output, and
// Settings → Debug Logs can silence a noisy feature at runtime without touching code
// (LogFeatureSettings).
//
// Levels: `.debug` is the default for anything that fires per-request/per-item — LLM prompts and
// raw responses, HTTP bodies, parse/salvage steps. `.info` marks a feature's notable lifecycle
// milestones (download started/finished, import completed). `.error` marks failures. Debug-level
// os_log entries are cheap and normally live only in the in-memory log buffer; nothing here is
// gated behind DEBUG at the call-site level so the same instrumentation is present in TestFlight
// and release builds too, in case a report needs one pulled after the fact.
//
// Every call takes its message as `@autoclosure () -> String` so a disabled feature never pays
// for building the string. Content is logged with `privacy: .private` — visible immediately when
// attached via Xcode (the normal way this gets read during development) but redacted if a log
// archive is ever pulled from a release build off-device, consistent with the app's "collects
// nothing" privacy policy for what is, after all, the user's own note/study text.
//
// The on-disk mirror (below) exists so a raw request/response is retrievable via
// `xcrun devicectl device copy from` even when Xcode isn't attached at the time — the scenario
// this feature was requested for. It's DEBUG-only: unlike os_log's `.private` redaction, the file
// sink writes plaintext, so it must never end up in a release/App-Store build's container.
enum AppLog {
    nonisolated private static let subsystem = "matthewmorrone.Kioku"

    nonisolated(unsafe) private static let loggers: [LogFeature: Logger] = Dictionary(
        uniqueKeysWithValues: LogFeature.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )

    // Every entry point is explicitly `nonisolated`: the project defaults to MainActor isolation
    // (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), but AppLog must be reachable from the
    // genuinely non-isolated contexts logging most needs to cover — URLSessionDelegate callbacks,
    // NWConnection completion handlers, Task.detached bodies — the same reason the bespoke
    // loggers this replaces (LLMDebugLog, KaraokeDebugLog) were nonisolated too.
    nonisolated static func debug(_ feature: LogFeature, _ message: @autoclosure () -> String) {
        emit(feature, level: .debug, message())
    }

    // Marks a feature's notable lifecycle milestones (download started/finished, import
    // completed) — worth persisting past the in-memory debug buffer, but not every request.
    nonisolated static func info(_ feature: LogFeature, _ message: @autoclosure () -> String) {
        emit(feature, level: .info, message())
    }

    // Marks a failure — network error, parse failure, validation rejection.
    nonisolated static func error(_ feature: LogFeature, _ message: @autoclosure () -> String) {
        emit(feature, level: .error, message())
    }

    // Shared implementation behind debug/info/error: checks the per-feature toggle once, then
    // fans out to both sinks (live os.Logger, on-disk mirror) so callers never duplicate that logic.
    nonisolated private static func emit(_ feature: LogFeature, level: OSLogType, _ text: String) {
        guard LogFeatureSettings.isEnabled(feature) else { return }
        loggers[feature]?.log(level: level, "\(text, privacy: .private)")
        #if DEBUG
        AppLogFileSink.write(feature: feature, level: level, text: text)
        #endif
    }
}
