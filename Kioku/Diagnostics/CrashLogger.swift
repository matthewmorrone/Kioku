import Foundation
import MetricKit
import UIKit

// Captures crashes from every channel iOS exposes and persists them as JSON in the app's
// Documents/crashes/ directory so they're retrievable via Files app, devicectl copy, or the
// Settings → Diagnostics → "Crash Logs" UI. Designed for the on-device crash forensics
// problem we hit earlier: sysdiagnose blocked by passcode-protected device, no Xcode
// connection at crash time, and OOM kills that leave no .ips trace anywhere.
//
// Three orthogonal capture paths because Swift's crash modes split across them:
//   1. NSSetUncaughtExceptionHandler — ObjC NSException leaks (mostly Foundation/UIKit bugs)
//   2. POSIX signal handlers — Swift force-unwrap nil, array bounds, fatalError (SIGTRAP/SIGILL),
//      and arbitrary memory faults (SIGSEGV/SIGBUS). Catchable in principle but constrained
//      to async-signal-safe operations; we pragmatically use backtrace() + write() and accept
//      the "may rarely deadlock the dying process" risk in exchange for stack traces.
//   3. MetricKit MXMetricManagerSubscriber — Apple's official post-mortem channel. Catches
//      OOM (MXAppExitMetric.cumulativeMemoryResourceLimitExitCount), watchdog terminations,
//      and any crash the system processed but the in-process handlers missed. Delivered the
//      NEXT app launch via didReceive(_:), so this is the only way to learn about kernel kills.
nonisolated final class CrashLogger: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = CrashLogger()

    private static let crashesDirectoryName = "crashes"

    // Public so Settings UI can list and dump entries. Read on the main thread when the user
    // taps "Crash Logs"; writes happen on background queues or signal handlers.
    var crashesDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent(Self.crashesDirectoryName, isDirectory: true)
    }

    // Wires up every capture path. Idempotent — repeated calls just re-install the same
    // handlers. Call once at app launch BEFORE any other work that might crash.
    func install() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: crashesDirectory, withIntermediateDirectories: true)

        // Dump any prior crashes to the console so they're visible if Xcode is attached and
        // self-evident in the device log stream. Files stay on disk for later retrieval too.
        surfacePreviousCrashes()

        NSSetUncaughtExceptionHandler { exception in
            // Extract values synchronously to avoid sending the exception across actors
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let userInfo = String(describing: exception.userInfo ?? [:])
            let callStack = exception.callStackSymbols

            Task { @MainActor in
                CrashLogger.writeExceptionCrash(name: name, reason: reason, userInfo: userInfo, callStack: callStack)
            }
        }

        installSignalHandlers()

        MXMetricManager.shared.add(self)
    }

    // Persists an ObjC exception with its callStackSymbols. NSSetUncaughtExceptionHandler runs
    // synchronously before the process dies, so we can use full Foundation APIs here.
    @MainActor private static func writeExceptionCrash(name: String, reason: String, userInfo: String, callStack: [String]) {
        let info = currentSystemInfo()
        let systemVersion = info.iosVersion
        let entry: [String: Any] = [
            "kind": "exception",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "name": name,
            "reason": reason,
            "userInfo": userInfo,
            "callStack": callStack,
            "appVersion": appVersionString(),
            "iosVersion": systemVersion,
            "deviceModel": info.deviceModel
        ]
        writeCrashFile(prefix: "exc", entry: entry)
    }

    // POSIX signal capture. The handler runs in async-signal-safe context, but we're already
    // committed to crashing so we pragmatically use Foundation APIs to write a structured
    // record. backtrace_symbols allocates internally — that's the standard approach used by
    // mature crash reporters (KSCrash, PLCrashReporter take similar liberties).
    private func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for signum in signals {
            signal(signum) { caught in
                Task { @MainActor in
                    CrashLogger.writeSignalCrash(signal: caught)
                }
                // Re-raise with the default handler so the process actually terminates and
                // upstream tools (Xcode debugger, MetricKit's next-launch payload) see the
                // crash too. Without this we'd swallow the signal and run with corrupted state.
                signal(caught, SIG_DFL)
                raise(caught)
            }
        }
    }

    // Captures the current backtrace via libsystem's backtrace(3) and writes a structured
    // crash record. Called from inside the POSIX signal handler — see installSignalHandlers
    // for the async-signal-safety caveats.
    @MainActor private static func writeSignalCrash(signal: Int32) {
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frameCount = backtrace(&addresses, 128)
        var stack: [String] = []
        if frameCount > 0, let symbols = backtrace_symbols(&addresses, frameCount) {
            for i in 0..<Int(frameCount) {
                if let cstr = symbols[i] {
                    stack.append(String(cString: cstr))
                }
            }
            free(symbols)
        }

        let info = currentSystemInfo()
        let systemVersion = info.iosVersion

        let entry: [String: Any] = [
            "kind": "signal",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "signal": signal,
            "signalName": signalName(signal),
            "callStack": stack,
            "appVersion": appVersionString(),
            "iosVersion": systemVersion,
            "deviceModel": info.deviceModel
        ]
        writeCrashFile(prefix: "sig", entry: entry)
    }

    // MetricKit delivers crash + hang payloads next-launch. The CrashDiagnostic includes the
    // full Apple-formatted call stack tree; AppExitMetric carries the OOM/watchdog buckets.
    // Both get persisted alongside the in-process captures.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Pre-extract the minimal, Sendable data from payloads synchronously to avoid sending
        // non-Sendable types across actors.
        struct CrashItem: Sendable {
            let timestamp: Date
            let exceptionType: Int
            let exceptionCode: Int
            let signal: Int
            let terminationReason: String
            let virtualMemoryRegionInfo: String
            let callStackTreeJSON: String
        }
        struct HangItem: Sendable {
            let timestamp: Date
            let hangDuration: Double
            let callStackTreeJSON: String
        }

        var crashes: [CrashItem] = []
        var hangs: [HangItem] = []

        for payload in payloads {
            let ts = payload.timeStampBegin
            if let crashDiags = payload.crashDiagnostics {
                for crash in crashDiags {
                    let item = CrashItem(
                        timestamp: ts,
                        exceptionType: crash.exceptionType?.intValue ?? -1,
                        exceptionCode: crash.exceptionCode?.intValue ?? -1,
                        signal: crash.signal?.intValue ?? -1,
                        terminationReason: crash.terminationReason ?? "(none)",
                        virtualMemoryRegionInfo: crash.virtualMemoryRegionInfo ?? "(none)",
                        callStackTreeJSON: String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                    )
                    crashes.append(item)
                }
            }
            if let hangDiags = payload.hangDiagnostics {
                for hang in hangDiags {
                    let item = HangItem(
                        timestamp: ts,
                        hangDuration: hang.hangDuration.value,
                        callStackTreeJSON: String(decoding: hang.callStackTree.jsonRepresentation(), as: UTF8.self)
                    )
                    hangs.append(item)
                }
            }
        }

        // Hop to main actor only to read system version; do not capture 'payloads'.
        Task { @MainActor in
            let systemVersion = UIDevice.current.systemVersion
            let appVersion = Self.appVersionString()

            // Write crashes
            for c in crashes {
                let entry: [String: Any] = [
                    "kind": "metrickit.crash",
                    "timestamp": ISO8601DateFormatter().string(from: c.timestamp),
                    "exceptionType": c.exceptionType,
                    "exceptionCode": c.exceptionCode,
                    "signal": c.signal,
                    "terminationReason": c.terminationReason,
                    "virtualMemoryRegionInfo": c.virtualMemoryRegionInfo,
                    "callStackTree": c.callStackTreeJSON,
                    "appVersion": appVersion,
                    "iosVersion": systemVersion
                ]
                Self.writeCrashFile(prefix: "mxk", entry: entry)
            }

            // Write hangs
            for h in hangs {
                let entry: [String: Any] = [
                    "kind": "metrickit.hang",
                    "timestamp": ISO8601DateFormatter().string(from: h.timestamp),
                    "hangDuration": h.hangDuration,
                    "callStackTree": h.callStackTreeJSON,
                    "appVersion": appVersion,
                    "iosVersion": systemVersion
                ]
                Self.writeCrashFile(prefix: "hang", entry: entry)
            }
        }
    }

    // Dump all persisted crash records to the console at startup. Visible in Xcode console
    // when attached, and in the device log stream (Console.app) when not.
    private func surfacePreviousCrashes() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: crashesDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files.sorted { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }

        guard sorted.isEmpty == false else { return }
        print("==== CrashLogger: \(sorted.count) prior crash record(s) on disk ====")
        for file in sorted {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            else { continue }
            print("---- \(file.lastPathComponent) ----")
            if let str = String(data: pretty, encoding: .utf8) { print(str) }
        }
        print("==== CrashLogger: end of prior crashes ====")
    }

    // Returns persisted crash files sorted newest-first, for Settings UI display.
    func listCrashFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashesDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        return files.sorted { lhs, rhs in
            lhs.lastPathComponent > rhs.lastPathComponent
        }
    }

    // Deletes every persisted crash file. Used after the user has reviewed and exported them.
    func clearCrashFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: crashesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Helpers

    @MainActor private static func currentSystemInfo() -> (iosVersion: String, deviceModel: String) {
        return (UIDevice.current.systemVersion, UIDevice.current.model)
    }

    // Serializes one crash/diagnostic entry to a timestamped JSON file in the crash dir.
    private static func writeCrashFile(prefix: String, entry: [String: Any]) {
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970)
        let url = CrashLogger.shared.crashesDirectory.appendingPathComponent("\(prefix)-\(stamp).json")
        guard let data = try? JSONSerialization.data(
            withJSONObject: entry,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            print("[CrashLogger] could not serialize crash entry for prefix=\(prefix)")
            return
        }
        // Surface persistence failures to the device log so a "lost" crash doesn't simply
        // vanish. If we reached this path from a signal handler the print itself carries the
        // same async-signal-safety risk the write() already accepts (see file header).
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("[CrashLogger] failed to persist \(prefix) crash to \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // Reads CFBundleShortVersionString + CFBundleVersion for the crash JSON header so we can
    // tell which build a record came from when reviewing older crashes after an update.
    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // Translates a POSIX signal number to its symbolic name for the crash JSON's signalName field.
    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "signal-\(signal)"
        }
    }
}
